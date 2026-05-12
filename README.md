# zephyrusctl

A unified profile manager for the ASUS ROG Zephyrus G14 (GA402RK). A single command switches the platform profile (`asusctl`), CPU power and thermal limits (`ryzenadj`), display refresh rate, GPU selection, CPU boost, and `powertop` tuning between predefined modes.

## Installation

    sudo make install

The installer places the script at `/usr/local/bin/zephyrusctl` and installs a systemd service and timer used by the persistence feature described below.

### Requirements

- `jq`, `asusctl`, `ryzenadj`, `powertop`
- **For refresh rate control (Wayland only):** One of `kscreen-doctor` (KDE), `gdctl` (GNOME), or `wlr-randr` (wlroots).
- A user account with passwordless `sudo` for `ryzenadj`, `powertop`, and the CPU boost sysfs node. On Arch Linux the `wheel` group is granted this by default; verify with `sudo -ln`.

## Usage

    zephyrusctl apply <profile>    # switch to a profile
    zephyrusctl list               # show available profile names
    zephyrusctl status             # show current settings and live readings
    zephyrusctl monitor [-t SEC]   # live temperature and fan readings

Five profiles ship by default:

| Profile       | Intended use                                  |
| ------------- | --------------------------------------------- |
| `low-power`   | Ultra-low 25W TDP for maximum battery life    |
| `powersave`   | Low-noise, low-power operation on battery     |
| `balanced`    | Everyday desktop use                          |
| `gaming`      | Performance fans with capped CPU temperatures |
| `performance` | Maximum performance, dedicated GPU forced     |

A typical workflow:

    zephyrusctl apply gaming
    # launch the application
    zephyrusctl apply balanced

Profiles are applied on demand only. The script does not run continuously and does not revert automatically. To switch profiles on AC connect/disconnect events, bind the appropriate `zephyrusctl apply` invocation to the relevant KDE Power Management action.

## Configuration

The shipped profiles are defined at the top of `/usr/local/bin/zephyrusctl`. To customize without modifying the installed script, create a partial override file at:

    ~/.config/zephyrusctl.json

Only the keys present in the override file are changed; unspecified keys inherit from the shipped configuration. For example, to lower the CPU temperature ceiling of the `gaming` profile:

    {
      "ryzenadj": {
        "gaming": { "cpu_temp": 80 }
      }
    }

Available `ryzenadj` knobs:

| Key             | Meaning                                                                                 |
| --------------- | --------------------------------------------------------------------------------------- |
| `tdp`           | Shortcut: sets all three power limits (with small burst headroom)                       |
| `stapm_limit`   | Sustained power limit (W)                                                               |
| `fast_limit`    | Short-burst power limit (W)                                                             |
| `slow_limit`    | Medium-term power limit (W)                                                             |
| `cpu_temp`      | CPU (Tctl) temperature ceiling (°C)                                                     |
| `gpu_skin_temp` | Chassis skin-temperature ceiling near the dGPU (°C). Not the GPU die temperature.       |
| `smu`           | Invoke a built-in SMU profile (see below)                                               |
| `inherit`       | Set to `false` to skip merging with the `base` preset (see below)                       |
| `persist`       | Re-apply these limits periodically (see below)                                          |

### Inheritance and the `base` preset

By default, every preset is merged on top of the `base` ryzenadj preset, so you only need to list the knobs that differ from `base`. Setting `"inherit": false` opts out of this merge — the preset stands alone with only the keys it declares.

### Power-saving and max-performance

ryzenadj has two built-in SMU profile flags, `--power-saving` and `--max-performance`, which set firmware-defined internal power policies. To invoke one, set the `smu` key to the desired flag name:

    "power-saving": { "smu": "power-saving", "cpu_temp": 70, "persist": true }

Setting a string value for `smu` automatically opts out of `base` inheritance and prepends the flag to the `ryzenadj` arguments.

## Behavior and limitations

The following are inherent to the underlying tools, not bugs in the script.

- **GPU selection applies to new processes only.** The `gpu` field writes Mesa environment variables; existing applications continue to use the GPU they were launched with. Apply the profile before starting the application.
- **`powertop --auto-tune` is not reversible.** It persists until the next reboot. Switching to a profile with `powertop: false` does not undo prior tuning.
- **`ryzenadj` limits drift under load.** AMD's SMU may revise the configured limits upward during sustained workloads. See [FlyGoat/RyzenAdj#374](https://github.com/FlyGoat/RyzenAdj/issues/374). To counter this, any `ryzenadj` preset may set `"persist": true`; a systemd timer then re-asserts the limits every 30 seconds while that profile is active. The shipped `gaming` profile has this enabled.
- **Profiles do not survive reboot or suspend.** Re-apply manually after waking the system.

## Monitoring

    zephyrusctl monitor [-t SEC]

Displays a three-row table (minimum, current, maximum) of CPU temperature, dGPU edge and junction temperatures, and CPU/GPU fan speeds. The default sampling interval is five seconds; override with `-t`. Press Ctrl-C to stop; the full sample history is written to a temporary file under `/tmp/` and its path is printed.

## Uninstallation

    sudo make uninstall
