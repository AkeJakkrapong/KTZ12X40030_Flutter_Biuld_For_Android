# KTZ12X40030 CAN Monitor

Android app for monitoring the **EC KTZ12X40030** motor controller over CAN bus via USB OTG.  
Built with Flutter. Supports CANable (SLCAN), Robotell, Waveshare USB-CAN adapters, and the CANalyst-II raw USB dongle.

---

## Features

- Real-time display of voltage, current, speed, shaft RPM, gear, and fault code
- Signal indicators: throttle confirm, brake signal/confirm, cruise control, handbrake
- Fault display card: motor temp, MCU temp, 12V rail, throttle analog, gear position, magnetic code, 4.096V ref, 5V supply
- Raw CAN frame table with cycle time (ms), pinning `0x0D259CD0` and `0x0D259CE7` at the top
- USB hotplug detection — no manual refresh needed
- Supercar-style dark UI (carbon black + champagne gold)

## Supported Hardware

| Adapter | Protocol |
|---------|----------|
| CANable / any SLCAN device | SLCAN (ASCII) |
| Robotell USB-CAN | Robotell binary |
| Waveshare USB-CAN | Waveshare binary |
| CANalyst-II (VID `0x04D8`, PID `0x0053`) | Raw USB (Kotlin plugin) |

## CAN Bus Parameters

- **Baud rate:** 250 kbps
- **Frame type:** Extended 29-bit
- **Byte order:** Intel (little-endian)

| CAN ID | Description | Cycle |
|--------|-------------|-------|
| `0x0D259CD0` | Instrument data (voltage, current, RPM, gear, fault) | 100 ms |
| `0x0D259CE7` | Fault display data (temps, rails, sensors) | 100 ms |

## Requirements

- Flutter 3.x
- Android device with USB OTG support (minSdk 21)
- One of the supported USB-CAN adapters

## Build

```powershell
# One-time setup
flutter pub get

# Stop Google Drive before building (prevents DEX file locking on Windows)
taskkill /IM "GoogleDriveFS.exe" /F
Remove-Item -Recurse -Force build

# Build release APK
flutter build apk --release --android-skip-build-dependency-validation
```

> Always use `--android-skip-build-dependency-validation` — AGP 8.7.3 is pinned for `usb_serial` compatibility.

## Install

```powershell
# Install (Windows)
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" install -r "build\app\outputs\flutter-apk\app-release.apk"

# If INSTALL_FAILED_UPDATE_INCOMPATIBLE, uninstall first:
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" uninstall com.bhl.ktz12x40030
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" install "build\app\outputs\flutter-apk\app-release.apk"
```

## App Icon

Regenerate icons from source image:

```bash
pip install Pillow
python gen_icon.py
```

Source image: `icon2.png` — outputs to `android/app/src/main/res/mipmap-*/ic_launcher.png`.

## Project Structure

```
lib/
  main.dart              # UI — supercar display, connection bar, metric/signal/fault cards
  decoder.dart           # Pure CAN frame decoders (no Flutter dependency)
  slcan_service.dart     # USB serial CAN service (SLCAN / Robotell / Waveshare)
  canalystii_service.dart# CANalyst-II raw USB service (MethodChannel + EventChannel)
android/app/src/main/kotlin/com/bhl/ktz12x40030/
  CanalystiiPlugin.kt    # Kotlin USB bulk-transfer plugin for CANalyst-II
  MainActivity.kt        # Registers CanalystiiPlugin
```

## Package

`com.bhl.ktz12x40030`
