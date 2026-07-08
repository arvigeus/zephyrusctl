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
    },
    "dgpu": { "gpu": "dGPU!" },
    "igpu": { "gpu": "iGPU!" },
    "hybrid": { "gpu": "auto" }
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

display_status_kde() {
	command -v kscreen-doctor > /dev/null || return 1

	local json
	json=$(kscreen-doctor -j 2> /dev/null) || return 1
	[[ -n "$json" ]] || return 1

	jq -er --arg n "$PANEL_NAME" '
        def refresh_suffix($m):
          ($m.refreshRate // $m.refresh // null) as $r
          | if $r == null then ""
            else
              " @ " + (
                if ($r | type) == "number"
                then (if $r > 1000 then ($r / 1000) else $r end | tostring)
                else ($r | tostring)
                end
              ) + " Hz"
            end;
        def mode_text($m):
          if ($m | type) != "object" then empty
          elif $m.size.width? and $m.size.height?
          then "\($m.size.width)x\($m.size.height)" + refresh_suffix($m)
          elif $m.name?
          then ($m.name | tostring | sub("@"; " @ ") | sub("Hz$"; " Hz"))
          else empty
          end;
        .outputs[]?
        | select(.name == $n or .type == "Panel" or .type == "panel")
        | . as $o
        | ($o.currentMode // ($o.modes[]? | select((.id | tostring) == ($o.currentModeId | tostring))) // {}) as $m
        | "  internal: \($o.name)",
          "    backend: KDE",
          "    state:   \(if ($o.enabled // false) then "enabled" else "disabled" end)",
	          (if ($o.enabled // false) then
	             (mode_text($m) as $mode | if $mode == "" then empty else "    mode:    \($mode)" end),
	             (if $o.scale? then "    scale:   \($o.scale)x" else empty end),
	             (if $o.primary? then "    primary: \($o.primary)" else empty end)
	           else empty end)
	    ' <<< "$json" | head -n 8
}

display_status_hyprland() {
	command -v hyprctl > /dev/null || return 1

	local json
	json=$(hyprctl monitors -j 2> /dev/null) || return 1
	[[ -n "$json" ]] || return 1

	jq -er --arg n "$PANEL_NAME" '
        .[]?
        | select(.name == $n or (.name | test("^(eDP|LVDS|DSI)-")))
        | "  internal: \(.name)",
	          "    backend: Hyprland",
	          "    state:   \(if (.disabled // false) then "disabled" else "enabled" end)",
	          (if (.disabled // false) then empty else "    mode:    \(.width)x\(.height) @ \(.refreshRate) Hz" end),
	          (if (.disabled // false) then empty else "    scale:   \(.scale)x" end),
	          (if (.focused? // false) then "    focused: true" else empty end)
	    ' <<< "$json" | head -n 8
}

display_status_wayland_info() {
	command -v wayland-info > /dev/null || return 1

	wayland-info 2> /dev/null | awk -v panel="$PANEL_NAME" '
        function flush() {
            if (name == "") return
            if (name == panel || name ~ /^(eDP|LVDS|DSI)-/) {
                print "  internal: " name
                print "    backend: Wayland"
	                print "    state:   enabled"
	                if (mode != "") print "    mode:    " mode
	                if (scale != "") print "    scale:   " scale "x"
	                found = 1
	                exit 0
	            }
        }
        /^interface: .wl_output/ {
	            flush()
	            in_output = 1
	            name = mode = scale = ""
	            current = 0
	            next
	        }
        /^interface:/ && in_output {
            flush()
            in_output = 0
            next
        }
        !in_output { next }
        /^[[:space:]]*name: / {
            sub(/^[[:space:]]*name: /, "")
            gsub(/^'\''|'\''$/, "")
            if ($0 !~ /^[0-9]+$/) name = $0
            next
        }
	        /^[[:space:]]*scale: / {
	            scale = $2
	            next
        }
        /^[[:space:]]*width: / {
            width = $2
            next
        }
        /^[[:space:]]*height: / {
            height = $2
            next
        }
        /^[[:space:]]*refresh: / {
            refresh = $2
            next
        }
        /^[[:space:]]*flags: .*current/ {
            if (width != "" && height != "") mode = width "x" height " @ " refresh " Hz"
            next
        }
        END {
            if (!found) flush()
            if (!found) exit 1
        }
    '
}

display_status_wlr() {
	command -v wlr-randr > /dev/null || return 1

	wlr-randr 2> /dev/null | awk -v panel="$PANEL_NAME" '
        function flush() {
            if (!in_output) return
            if (name == panel || name ~ /^(eDP|LVDS|DSI)-/) {
                print "  internal: " name
                print "    backend: wlroots"
	                print "    state:   " (enabled == "yes" ? "enabled" : "disabled")
	                if (enabled == "yes" && mode != "") print "    mode:    " mode
	                if (enabled == "yes" && scale != "") print "    scale:   " scale "x"
	                found = 1
	                exit 0
	            }
        }
	        /^[^[:space:]]/ {
	            flush()
	            in_output = 1
	            name = $1
	            enabled = mode = scale = ""
	            next
	        }
        !in_output { next }
        /^[[:space:]]*Enabled:/ {
            enabled = $2
            next
        }
        /^[[:space:]]*Scale:/ {
            scale = $2
            next
        }
	        /\(.*current.*\)/ {
	            line = $0
            sub(/^[[:space:]]*/, "", line)
            sub(/ px, /, " @ ", line)
            sub(/ Hz.*/, " Hz", line)
            mode = line
            next
        }
        END {
            if (!found) flush()
            if (!found) exit 1
        }
    '
}

display_status_gnome() {
	command -v gdctl > /dev/null || return 1

	local out enabled
	out=$(gdctl show 2> /dev/null) || return 1
	[[ -n "$out" ]] || return 1
	if sed -n '/Logical monitors:/,$p' <<< "$out" | grep -q "$PANEL_NAME"; then
		enabled=enabled
	else
		enabled=disabled
	fi

	printf '  internal: %s\n' "$PANEL_NAME"
	printf '    backend: GNOME\n'
	printf '    state:   %s\n' "$enabled"
}

normalize_refresh_rate() {
	awk -v r="$1" 'BEGIN {
        if (r == "") exit 1
        sub(/Hz$/, "", r)
        if (r + 0 == int(r + 0)) printf "%d\n", r + 0
        else printf "%.2f\n", r + 0
    }'
}

drm_refresh_from_edid() {
	command -v edid-decode > /dev/null || return 1

	local dir="$1" mode="$2"
	[[ -r "$dir/edid" ]] || return 1

	edid-decode "$dir/edid" 2> /dev/null | awk -v mode="$mode" '
        $1 == "DTD" && $3 == mode && $5 == "Hz" {
            print $4
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' | {
		read -r refresh
		normalize_refresh_rate "$refresh"
	}
}

drm_refresh_rate() {
	local dir="$1" mode="$2"

	drm_refresh_from_edid "$dir" "$mode"
}

display_status_drm() {
	local d enabled refresh status mode name chosen=""

	for d in /sys/class/drm/card*-*; do
		[[ -d "$d" ]] || continue
		name=${d##*/}
		name=${name#card*-}
		[[ "$name" == "$PANEL_NAME" ]] || continue
		chosen="$d"
		break
	done

	if [[ -z "$chosen" ]]; then
		for d in /sys/class/drm/card*-*; do
			[[ -d "$d" ]] || continue
			name=${d##*/}
			name=${name#card*-}
			[[ "$name" =~ ^(eDP|LVDS|DSI)- ]] || continue
			status=$(cat "$d/status" 2> /dev/null || echo unknown)
			enabled=$(cat "$d/enabled" 2> /dev/null || echo unknown)
			[[ "$status" == "connected" || "$enabled" == "enabled" ]] || continue
			chosen="$d"
			break
		done
	fi

	if [[ -z "$chosen" ]]; then
		for d in /sys/class/drm/card*-*; do
			[[ -d "$d" ]] || continue
			name=${d##*/}
			name=${name#card*-}
			[[ "$name" =~ ^(eDP|LVDS|DSI)- ]] || continue
			chosen="$d"
			break
		done
	fi

	[[ -n "$chosen" ]] || return 1

	d="$chosen"
	name=${d##*/}
	name=${name#card*-}
	status=$(cat "$d/status" 2> /dev/null || echo unknown)
	enabled=$(cat "$d/enabled" 2> /dev/null || echo unknown)
	mode=$(head -n 1 "$d/modes" 2> /dev/null || true)
	refresh=""
	if [[ -n "$mode" ]]; then
		refresh=$(drm_refresh_rate "$d" "$mode" 2> /dev/null || true)
	fi

	printf '  internal: %s\n' "$name"
	printf '    backend: DRM\n'
	printf '    state:   %s\n' "$enabled"
	printf '    status:  %s\n' "$status"
	if [[ -n "$mode" && -n "$refresh" ]]; then
		printf '    mode:    %s @ %s Hz\n' "$mode" "$refresh"
	elif [[ -n "$mode" ]]; then
		printf '    mode:    %s\n' "$mode"
	fi
	return 0
}

print_internal_display_status() {
	echo "Display:"
	if display_status_kde ||
		display_status_hyprland ||
		display_status_wayland_info ||
		display_status_wlr ||
		display_status_gnome ||
		display_status_drm; then
		return 0
	fi

	printf '  internal: %s\n' "$PANEL_NAME"
	printf '    state:   unavailable\n'
}

find_battery() {
	local d type
	for d in /sys/class/power_supply/*; do
		[[ -e "$d/type" ]] || continue
		type=$(cat "$d/type" 2> /dev/null || true)
		[[ "$type" == "Battery" ]] || continue
		echo "$d"
		return 0
	done
	return 1
}

print_battery_status() {
	local bat capacity limit status
	bat=$(find_battery) || return 0

	capacity=$(cat "$bat/capacity" 2> /dev/null || true)
	status=$(cat "$bat/status" 2> /dev/null || true)
	limit=$(cat "$bat/charge_control_end_threshold" 2> /dev/null || true)

	echo "Battery:"
	printf '  name:         %s\n' "${bat##*/}"
	[[ -n "$status"   ]] && printf '  status:       %s\n' "$status"
	[[ -n "$capacity" ]] && printf '  capacity:     %s%%\n' "$capacity"
	if [[ -n "$limit" ]]; then
		printf '  charge-limit: %s%%\n' "$limit"
	else
		printf '  charge-limit: unavailable\n'
	fi
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
	print_internal_display_status
	print_battery_status

	if command -v asusctl > /dev/null; then
		local prof
		prof=$(asusctl profile get 2> /dev/null | awk -F': ' '/Active profile/{print $2; exit}' || true)
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
        ' || true
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
