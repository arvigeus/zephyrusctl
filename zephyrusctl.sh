#!/usr/bin/env bash
# zephyrusctl — hardware control for ASUS ROG Zephyrus G14 (GA402RK)
#
# Single-file, no state. Defaults live in the CONFIG heredoc below.
# Optional partial overrides at $USER_CONFIG (XDG path) are merged via jq's
# recursive `*` — set only the keys you want to change.
set -euo pipefail

# ---- Hardware constants (GA402RK-L8149) ---------------------------------
PANEL_NAME="eDP-2"
PANEL_RES="2560x1600"
IGPU_PCI="1002:1681" # AMD Rembrandt
DGPU_PCI="1002:73ff" # AMD Navi 23
DGPU_SLOT="0000:03:00.0"

# Optional persistent GPU selection. Plain dGPU/iGPU uses only runtime state;
# dGPU!/iGPU! writes this file so the setting survives reboot.
GPU_ENVFILE="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/zephyrusctl.conf"

# Optional user overrides. Read once at startup if present.
USER_CONFIG="$HOME/.config/zephyrusctl.json"

# ---- Profile config -----------------------------------------------------
# Three sections:
#   defaults  - fallback knob values; profiles inherit anything they don't set
#   ryzenadj  - named presets of explicit knobs (watts and °C)
#   profiles  - named bundles; the `ryzenadj` field names either an entry in
#               the table above, or one of ryzenadj's two built-in SMU flags
#               (power-saving | max-performance) — preset table wins on name
#               collision.
#
# The `default` ryzenadj preset mirrors the firmware ceilings observed on
# Balanced + AC for this GA402RK. They're high enough that the SMU never
# actually hits them, which is the intended "no imposed limit" state.
read -r -d '' CONFIG << 'JSON' || true
{
  "defaults": {
    "asus_profile": "Balanced",
    "cpu_boost": true,
    "gpu": "auto",
    "refresh_rate": 120,
    "powertop": false,
    "ryzenadj": "base"
  },
  "ryzenadj": {
    "base": {
      "stapm_limit": 125,
      "fast_limit": 125,
      "slow_limit": 100,
      "cpu_temp": 93,
      "gpu_skin_temp": 46
    },
    "low-power": {
      "smu": "power-saving",
      "tdp": 25,
      "cpu_temp": 60,
      "persist": true
    },
    "power-saving": {
      "smu": "power-saving",
      "cpu_temp": 70,
      "persist": true
    },
    "max-performance": { "smu": "max-performance" },
    "gaming": {
      "inherit": false,
      "cpu_temp": 85,
      "persist": true
    }
  },
  "profiles": {
    "low-power": {
      "asus_profile": "Quiet",
      "cpu_boost": false,
      "gpu": "iGPU",
      "refresh_rate": 60,
      "powertop": true,
      "ryzenadj": "low-power"
    },
    "powersave": {
      "asus_profile": "Quiet",
      "cpu_boost": false,
      "gpu": "iGPU",
      "refresh_rate": 60,
      "powertop": true,
      "ryzenadj": "power-saving"
    },
    "balanced": {
      "asus_profile": "Balanced"
    },
    "gaming": {
      "asus_profile": "Performance",
      "cpu_boost": false,
      "gpu": "dGPU",
      "ryzenadj": "gaming"
    },
    "performance": {
      "asus_profile": "Performance",
      "gpu": "dGPU",
      "ryzenadj": "max-performance"
    }
  }
}
JSON

# ---- Logging ------------------------------------------------------------
log() { printf '%s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# ---- Dependencies -------------------------------------------------------
for _cmd in jq asusctl ryzenadj; do
	command -v "$_cmd" > /dev/null || die "missing dependency: $_cmd"
done
unset _cmd

# ---- User overrides -----------------------------------------------------
# Merge $USER_CONFIG into CONFIG (recursive: only set keys win).
if [[ -f "$USER_CONFIG" ]]; then
	CONFIG=$(jq -nc --argjson b "$CONFIG" --slurpfile u "$USER_CONFIG" '$b * $u[0]') ||
		die "failed to merge $USER_CONFIG (check JSON syntax)"
fi

# ---- Dispatchers --------------------------------------------------------

apply_asus_profile() {
	local p="$1"
	[[ -z "$p" ]] && return 0
	asusctl profile set "$p" > /dev/null
}

apply_cpu_boost() {
	# System-wide knob; per-CPU /sys files mirror this value automatically.
	local v="$1" sysfs_v
	[[ -z "$v" ]] && return 0
	case "$v" in
		true) sysfs_v=1 ;;
		false) sysfs_v=0 ;;
		*) die "invalid cpu_boost: $v (use true or false)" ;;
	esac
	sudo tee /sys/devices/system/cpu/cpufreq/boost > /dev/null <<< "$sysfs_v"
}

apply_refresh_rate() {
	local rate="$1"
	[[ -z "$rate" ]] && return 0

	# 1. KDE Plasma (kscreen-doctor)
	if command -v kscreen-doctor > /dev/null; then
		# Skip when the panel isn't enabled (lid closed, no Plasma session, etc.).
		kscreen-doctor -j 2> /dev/null |
			jq -e --arg n "$PANEL_NAME" '.outputs[] | select(.name==$n) | .enabled' > /dev/null 2>&1 ||
			return 0
		kscreen-doctor "output.${PANEL_NAME}.mode.${PANEL_RES}@${rate}" > /dev/null || true

	# 2. GNOME (gdctl)
	elif command -v gdctl > /dev/null; then
		# A monitor is enabled only if it appears under a 'Logical monitor' entry.
		gdctl show 2> /dev/null | sed -n '/Logical monitors:/,$p' | grep -q "$PANEL_NAME" || return 0
		gdctl set-refresh-rate "$PANEL_NAME" "$rate" > /dev/null || true

	# 3. wlroots (Sway, Hyprland, etc. via wlr-randr)
	elif command -v wlr-randr > /dev/null; then
		# Look for the output block and verify it says 'Enabled: yes'.
		wlr-randr 2> /dev/null | grep -A 10 "$PANEL_NAME" | grep -q "Enabled: yes" || return 0
		wlr-randr --output "$PANEL_NAME" --mode "${PANEL_RES}@${rate}Hz" > /dev/null || true
	fi
}

apply_gpu() {
	# MESA_VK_DEVICE_SELECT / DRI_PRIME in the systemd user manager only affect
	# new processes spawned from that manager. Plain dGPU/iGPU values are
	# in-memory state and disappear when the user manager exits, including on
	# reboot. Add ! to opt in to environment.d persistence.
	local mode="$1"
	[[ -z "$mode" ]] && return 0
	case "$mode" in
		dGPU)
			rm -f "$GPU_ENVFILE"
			systemctl --user set-environment DRI_PRIME=1 "MESA_VK_DEVICE_SELECT=$DGPU_PCI!"
			;;
		iGPU)
			rm -f "$GPU_ENVFILE"
			systemctl --user set-environment DRI_PRIME=0 "MESA_VK_DEVICE_SELECT=$IGPU_PCI!"
			;;
		dGPU!)
			mkdir -p "$(dirname "$GPU_ENVFILE")"
			printf 'DRI_PRIME=1\nMESA_VK_DEVICE_SELECT=%s!\n' "$DGPU_PCI" > "$GPU_ENVFILE"
			systemctl --user set-environment DRI_PRIME=1 "MESA_VK_DEVICE_SELECT=$DGPU_PCI!"
			;;
		iGPU!)
			mkdir -p "$(dirname "$GPU_ENVFILE")"
			printf 'DRI_PRIME=0\nMESA_VK_DEVICE_SELECT=%s!\n' "$IGPU_PCI" > "$GPU_ENVFILE"
			systemctl --user set-environment DRI_PRIME=0 "MESA_VK_DEVICE_SELECT=$IGPU_PCI!"
			;;
		auto)
			rm -f "$GPU_ENVFILE"
			systemctl --user unset-environment DRI_PRIME MESA_VK_DEVICE_SELECT
			;;
		*) die "invalid gpu: $mode (use auto, dGPU, iGPU, dGPU!, or iGPU!)" ;;
	esac
}

apply_powertop() {
	# powertop --auto-tune is one-shot and persists until reboot — there is
	# no clean undo. Only invoked when target asks for it; switching to a
	# profile with powertop=false does not reverse prior tuning.
	local v="$1"
	[[ "$v" != "true" ]] && return 0
	sudo powertop --auto-tune > /dev/null
}

persist_enable() {
	local args=("$@")
	sudo install -d -m 0755 /var/lib/zephyrusctl
	printf 'ARGS="%s"\n' "${args[*]}" | sudo tee /var/lib/zephyrusctl/ryzenadj.args > /dev/null
	sudo systemctl start zephyrusctl.timer 2> /dev/null ||
		log "warn: zephyrusctl.timer not installed; run 'sudo make install' to enable persist"
}

persist_disable() {
	sudo systemctl stop zephyrusctl.timer 2> /dev/null || true
	sudo rm -f /var/lib/zephyrusctl/ryzenadj.args 2> /dev/null || true
}

apply_ryzenadj() {
	# Preset resolution:
	#   1. Key in CONFIG.ryzenadj → if the preset sets `inherit: false` or has
	#      a `smu` flag defined, the preset is used verbatim (no merge with
	#      .ryzenadj.base). If `smu` is a string (power-saving | max-performance),
	#      that flag is prepended to the ryzenadj args.
	#      Explicit knobs the preset declares are always applied. Without
	#      `inherit: false` or `smu`, the preset is merged with .ryzenadj.base
	#      (named wins). `persist` controls whether zephyrusctl.timer
	#      re-applies these args every 30 s.
	#   2. Otherwise, if the name is power-saving or max-performance → fallback
	#      direct SMU-flag invocation (for configs that removed the table
	#      entry). No persist.
	local name="$1"
	[[ -z "$name" || "$name" == "null" ]] && return 0

	local exists
	exists=$(jq -r --arg n "$name" '.ryzenadj | has($n)' <<< "$CONFIG")
	if [[ "$exists" == "true" ]]; then
		# `tdp` is a shortcut: stapm_limit and slow_limit are set to `tdp`,
		# fast_limit gets a small +2 W headroom for short bursts. Explicit
		# stapm_limit/fast_limit/slow_limit in the same preset override these.
		# Expand before any merge with .ryzenadj.base.
		local resolved
		resolved=$(jq -c --arg n "$name" '
            (.ryzenadj[$n] // {})
            | if has("tdp")
              then {stapm_limit: .tdp, fast_limit: (.tdp + 2), slow_limit: .tdp} * .
              else . end
        ' <<< "$CONFIG")
		local smu
		smu=$(jq -r '.smu // empty' <<< "$resolved")
		local inherit
		inherit=$(jq -r '.inherit // true' <<< "$resolved")

		local preset args=()
		if [[ -n "$smu" || "$inherit" == "false" ]]; then
			preset="$resolved" # explicit opt-out or smu skips base-inheritance
			[[ -n "$smu" ]] && args=(--"$smu")
		else
			preset=$(jq -nc --argjson b "$(jq -c '.ryzenadj.base // {}' <<< "$CONFIG")" --argjson p "$resolved" '$b * $p')
		fi

		local v
		v=$(jq -r '.stapm_limit   // empty' <<< "$preset")
		[[ -n "$v"                                       ]] && args+=(--stapm-limit "$((v * 1000))")
		v=$(jq -r '.fast_limit    // empty' <<< "$preset")
		[[ -n "$v"                                       ]] && args+=(--fast-limit "$((v * 1000))")
		v=$(jq -r '.slow_limit    // empty' <<< "$preset")
		[[ -n "$v"                                       ]] && args+=(--slow-limit "$((v * 1000))")
		v=$(jq -r '.cpu_temp      // empty' <<< "$preset")
		[[ -n "$v"                                       ]] && args+=(--tctl-temp "$v")
		v=$(jq -r '.gpu_skin_temp // empty' <<< "$preset")
		[[ -n "$v"                                       ]] && args+=(--dgpu-skin-temp "$v")

		if ((${#args[@]} > 0)); then
			sleep 1 # let firmware settle after asusctl profile change
			sudo ryzenadj "${args[@]}" > /dev/null
		fi

		local persist
		persist=$(jq -r '.persist // false' <<< "$preset")
		if [[ "$persist" == "true" ]]; then
			persist_enable "${args[@]}"
		else
			persist_disable
		fi
		return 0
	fi

	case "$name" in
		power-saving | max-performance)
			sleep 1
			sudo ryzenadj "--$name" > /dev/null
			persist_disable
			;;
		*) die "unknown ryzenadj preset: $name" ;;
	esac
}

# ---- Commands -----------------------------------------------------------

cmd_apply() {
	local name="$1"
	[[ -z "$name" ]] && die "usage: zephyrusctl apply <profile>"

	local prof
	prof=$(jq -c --arg n "$name" '.profiles[$n] // empty' <<< "$CONFIG")
	[[ -z "$prof" || "$prof" == "null" ]] && die "unknown profile: $name"

	local defaults
	defaults=$(jq -c '.defaults // {}' <<< "$CONFIG")
	local target
	target=$(jq -nc --argjson d "$defaults" --argjson p "$prof" '$d * $p')

	apply_asus_profile "$(jq -r '.asus_profile // empty' <<< "$target")"
	apply_cpu_boost "$(jq -r '.cpu_boost    // empty' <<< "$target")"
	apply_refresh_rate "$(jq -r '.refresh_rate // empty' <<< "$target")"
	apply_gpu "$(jq -r '.gpu          // empty' <<< "$target")"
	apply_powertop "$(jq -r '.powertop     // false' <<< "$target")"
	apply_ryzenadj "$(jq -r '.ryzenadj     // empty' <<< "$target")"

	log "applied profile: $name"
}

cmd_list() {
	jq -r '.profiles | keys[]' <<< "$CONFIG" | sort
}

# ---- Monitor ------------------------------------------------------------

# First hwmon directory whose `name` file equals $1.
find_hwmon() {
	local target="$1" h
	for h in /sys/class/hwmon/hwmon*; do
		[[ -e "$h/name" ]] || continue
		[[ "$(cat "$h/name")" == "$target" ]] && {
			echo "$h"
			return 0
		}
	done
	return 1
}

# The amdgpu hwmon whose underlying PCI device is the dGPU (vs. iGPU).
find_dgpu_hwmon() {
	local h link
	for h in /sys/class/hwmon/hwmon*; do
		[[ -e "$h/name" ]] || continue
		[[ "$(cat "$h/name")" == "amdgpu" ]] || continue
		link=$(readlink -f "$h/device" 2> /dev/null || true)
		[[ "$link" == *"$DGPU_SLOT"* ]] && {
			echo "$h"
			return 0
		}
	done
	return 1
}

read_temp_c() {
	# hwmon temperature files report millidegrees; return °C as integer.
	local v
	v=$(cat "$1" 2> /dev/null || true)
	[[ -z "$v" ]] && {
		echo "-"
		return
	}
	echo $((v / 1000))
}

read_fan_rpm() {
	# Round to nearest 100 so the dedup signature is stable.
	local v
	v=$(cat "$1" 2> /dev/null || true)
	[[ -z "$v" ]] && {
		echo "-"
		return
	}
	echo $(((v + 50) / 100 * 100))
}

update_minmax() {
	local -n _min="min_$1" _max="max_$1"
	local v="$2"
	[[ "$v" == "-" ]] && return 0
	if [[ -z "$_min" ]] || ((v < _min)); then _min="$v"; fi
	if [[ -z "$_max" ]] || ((v > _max)); then _max="$v"; fi
}

monitor_flush() {
	if ((${#samples[@]} > 0)); then
		{
			echo "$sample_header"
			printf '%s\n' "${samples[@]}"
		} > "$logfile"
		printf '\n%d samples written to %s\n' "${#samples[@]}" "$logfile" >&2
	else
		rm -f "$logfile"
		printf '\nno samples captured\n' >&2
	fi
	exit 0
}

cmd_monitor() {
	local interval=5
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-t)
				interval="$2"
				shift 2
				;;
			*) die "monitor: unknown arg '$1' (use -t <seconds>)" ;;
		esac
	done

	local cpu_hwmon dgpu_hwmon fan_hwmon
	cpu_hwmon=$(find_hwmon k10temp) || die "k10temp hwmon not found"
	dgpu_hwmon=$(find_dgpu_hwmon) || die "amdgpu hwmon for dGPU not found"
	fan_hwmon=$(find_hwmon asus) || die "asus hwmon (fans) not found"

	local logfile
	logfile=$(mktemp --suffix=.log /tmp/zephyrusctl-monitor.XXXXXX)
	local sample_header
	sample_header=$(printf '%-8s  %5s  %5s  %6s  %7s  %7s' "time" "cpu°C" "gpu°C" "junc°C" "cpu_fan" "gpu_fan")
	local display_header
	display_header=$(printf '%-8s  %5s  %5s  %6s  %7s  %7s' "" "cpu°C" "gpu°C" "junc°C" "cpu_fan" "gpu_fan")

	local -a samples=()
	local last=""
	local min_cpu="" max_cpu=""
	local min_gpu="" max_gpu=""
	local min_junc="" max_junc=""
	local min_cpu_fan="" max_cpu_fan=""
	local min_gpu_fan="" max_gpu_fan=""

	trap monitor_flush INT TERM
	printf 'monitoring every %ds (Ctrl-C to stop)\n' "$interval"
	echo "$display_header"

	local first=1
	while true; do
		local ts cpu gpu junc cpu_fan gpu_fan row sig
		ts=$(date +%H:%M:%S)
		cpu=$(read_temp_c "$cpu_hwmon/temp1_input")
		gpu=$(read_temp_c "$dgpu_hwmon/temp1_input")
		junc=$(read_temp_c "$dgpu_hwmon/temp2_input")
		cpu_fan=$(read_fan_rpm "$fan_hwmon/fan1_input")
		gpu_fan=$(read_fan_rpm "$fan_hwmon/fan2_input")

		sig="$cpu|$gpu|$junc|$cpu_fan|$gpu_fan"
		if [[ "$sig" != "$last" ]]; then
			row=$(printf '%-8s  %5s  %5s  %6s  %7s  %7s' "$ts" "$cpu" "$gpu" "$junc" "$cpu_fan" "$gpu_fan")
			samples+=("$row")
			last="$sig"
		fi

		update_minmax cpu "$cpu"
		update_minmax gpu "$gpu"
		update_minmax junc "$junc"
		update_minmax cpu_fan "$cpu_fan"
		update_minmax gpu_fan "$gpu_fan"

		# Redraw the 3-row min/current/max table in place.
		if ((first == 0)); then printf '\033[3A\033[J'; fi
		first=0
		printf '%-8s  %5s  %5s  %6s  %7s  %7s\n' "min" "${min_cpu:--}" "${min_gpu:--}" "${min_junc:--}" "${min_cpu_fan:--}" "${min_gpu_fan:--}"
		printf '%-8s  %5s  %5s  %6s  %7s  %7s\n' "current" "$cpu" "$gpu" "$junc" "$cpu_fan" "$gpu_fan"
		printf '%-8s  %5s  %5s  %6s  %7s  %7s\n' "max" "${max_cpu:--}" "${max_gpu:--}" "${max_junc:--}" "${max_cpu_fan:--}" "${max_gpu_fan:--}"

		sleep "$interval"
	done
}

cmd_status() {
	local boost
	boost=$(cat /sys/devices/system/cpu/cpufreq/boost 2> /dev/null || echo "")
	case "$boost" in
		1) echo "CPU Boost: Enabled" ;;
		0) echo "CPU Boost: Disabled" ;;
		*) echo "CPU Boost: (unavailable)" ;;
	esac

	local gpu="auto" env
	env=$(systemctl --user show-environment 2> /dev/null || true)
	if [[ -f "$GPU_ENVFILE" ]] && grep -Fxq "MESA_VK_DEVICE_SELECT=$DGPU_PCI!" "$GPU_ENVFILE"; then
		gpu="dGPU!"
	elif [[ -f "$GPU_ENVFILE" ]] && grep -Fxq "MESA_VK_DEVICE_SELECT=$IGPU_PCI!" "$GPU_ENVFILE"; then
		gpu="iGPU!"
	elif grep -Fxq "MESA_VK_DEVICE_SELECT=$DGPU_PCI!" <<< "$env"; then
		gpu="dGPU"
	elif grep -Fxq "MESA_VK_DEVICE_SELECT=$IGPU_PCI!" <<< "$env"; then
		gpu="iGPU"
	fi
	echo "GPU: $gpu"
	local runtime
	runtime=$(cat "/sys/bus/pci/devices/$DGPU_SLOT/power/runtime_status" 2> /dev/null || echo unknown)
	echo "  dGPU:"
	echo "    runtime: $runtime"
	# Only read power_state when the device is already active. On AMD platforms
	# this path can briefly wake the device from D3cold.
	if [[ "$runtime" == "active" ]]; then
		echo "    state:   $(cat "/sys/bus/pci/devices/$DGPU_SLOT/power_state" 2> /dev/null || echo unknown)"
	fi

	if command -v asusctl > /dev/null; then
		local prof
		prof=$(asusctl profile get 2> /dev/null | awk -F': ' '/Active profile/{print $2; exit}')
		echo "asusctl: ${prof:-unknown}"
	fi

	if command -v ryzenadj > /dev/null; then
		echo "ryzenadj:"
		sudo ryzenadj -i 2> /dev/null | awk -F'|' '
            function num(s) { gsub(/^ +| +$/, "", s); sub(/\..*/, "", s); return s }
            /STAPM LIMIT/    { printf "  %-15s %3s W\n",  "stapm-limit:",    num($3) }
            /PPT LIMIT FAST/ { printf "  %-15s %3s W\n",  "fast-limit:",     num($3) }
            /PPT LIMIT SLOW/ { printf "  %-15s %3s W\n",  "slow-limit:",     num($3) }
            /PPT LIMIT APU/  { printf "  %-15s %3s W\n",  "apu-slow-limit:", num($3) }
            /THM LIMIT CORE/ { printf "  %-15s %3s °C\n", "tctl-temp:",      num($3) }
            /STT LIMIT APU/  { printf "  %-15s %3s °C\n", "apu-skin-temp:",  num($3) }
            /STT LIMIT dGPU/ { printf "  %-15s %3s °C\n", "dgpu-skin-temp:", num($3) }
        '
	fi
}

usage() {
	cat >&2 << 'USAGE'
usage:
  zephyrusctl apply <name>      switch to a profile (see 'list')
  zephyrusctl list              show available profile names
  zephyrusctl status            live ryzenadj + asusctl readings
  zephyrusctl monitor [-t SEC]  sample temps/fans (default 5s), log on Ctrl-C
USAGE
}

case "${1:-}" in
	apply) cmd_apply "${2:-}" ;;
	list) cmd_list ;;
	status) cmd_status ;;
	monitor) cmd_monitor "${@:2}" ;;
	-h | --help | help | "") usage ;;
	*)
		usage
		exit 64
		;;
esac
