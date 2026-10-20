# Mac FanPilot

A free, open-source menu-bar app for Apple Silicon Macs (M1/M2/M3…) that shows live temperatures, memory usage and fan speeds, and lets you take control of the fans.

## Features

- **Live stats** — CPU & GPU temperature (average + hottest core), memory used, swap, and per-fan RPM.
- **Fan modes**
  - **Normal** — Apple's default fan control (quiet).
  - **Boost** — fans fixed at ~65%; good for long exports and builds.
  - **Pro** — fans follow CPU temperature on an aggressive, adjustable curve (ramp-up and full-speed temperatures) for sustained heavy work.
  - **Max** — full speed.
  - **Custom** — pick any fixed speed.
- **RAM optimizer** — see your top memory-hungry apps (helper processes like browser tabs are counted toward their app), quit them in one click, and flush cached memory with **Free Up RAM**.
- **Performance tab** — one-tap **Turbo** (Low Power Mode off + Pro fan curve + no idle sleep), plus separate Low Power Mode and Keep Awake switches.
- **One-time password** — a small root-owned helper is installed once; mode changes never prompt again.
- **Open at login**, and your last mode is restored at startup and after sleep.
- **Quit** always hands the fans back to Normal.

> **About performance:** Apple Silicon can't be overclocked — clock speeds are locked by Apple, and any app claiming otherwise is fake. More airflow only helps under *sustained* load, where it reduces thermal throttling so the chip holds its top clock speed for longer. Fanless Macs (e.g. MacBook Air M1) have no fans to control.

## Build & install

Requires Xcode Command Line Tools (`xcode-select --install`) and macOS 14+.

```bash
./build.sh install
```

This builds `FanPilot.app`, copies it to `/Applications` and launches it. Use `./build.sh` alone to build into `build/` without installing.

The first time you pick a mode other than Normal, macOS asks for your password once to install the helper at `/usr/local/libexec/fanpilot/fanctl`. Remove it any time with **Uninstall helper** in the menu.

## Command line

The bundled `fanctl` tool also works on its own:

```bash
fanctl status        # JSON: temperatures + fans
fanctl set 3000      # all fans to 3000 RPM (or "max"); needs root
fanctl auto          # back to Apple's control; needs root
fanctl keys          # dump all readable SMC sensors
fanctl purge         # flush cached memory; needs root
fanctl lowpower 0|1  # toggle Low Power Mode; needs root
```

## How it works

- `Sources/smc.c` — talks to the Apple SMC through IOKit (read/write keys such as `F0Ac`, `F0Tg`, `F0Md`, `Ftst`).
- `Sources/fanctl.c` — the CLI / privileged helper.
- `Sources/FanPilotApp.swift` — app model: polling, modes, Pro curve, helper install, login item.
- `Sources/SystemTools.swift` — RAM optimizer, Low Power Mode, Turbo, keep-awake.
- `Sources/MenuView.swift` — the SwiftUI menu-bar panel.

## Disclaimer

Changing fan behaviour is at your own risk. FanPilot never sets fans below the hardware minimum, and Normal mode returns full control to macOS.

## License

MIT
