# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this repository.

## Building and running

```powershell
# One-time setup (requires Flutter installed)
flutter pub get

# Build release APK
flutter build apk --release --android-skip-build-dependency-validation

# Install on connected Android device (Windows — adb in LOCALAPPDATA)
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" install -r build\app\outputs\flutter-apk\app-release.apk

# Before each build: stop Google Drive and clean build dir to avoid file locking
taskkill /IM "GoogleDriveFS.exe" /F
Remove-Item -Recurse -Force build
```

> **Windows build tip:** Google Drive and Windows Defender both lock DEX files during compilation.
> - Stop Google Drive before building, restart after.
> - Add the `build\` folder to Defender exclusions: `Add-MpPreference -ExclusionPath "<project>\build"`
> - Always use `--android-skip-build-dependency-validation` — AGP 8.7.3 is below Flutter 3.44.1's preferred minimum but required for `usb_serial` (`jcenter()` removed in AGP 9+).

## Architecture

Four files under `lib/`:

1. **`decoder.dart`** — Pure functions, no Flutter dependency:
   - `decodeInstrument(List<int> data)` → `InstrumentData` — parses CAN ID `0x0D259CD0`
   - `decodeFaultDisplay(List<int> data)` → `FaultDisplayData` — parses CAN ID `0x0D259CE7`
   - `kFaultCodes` map (0–8), `kSpeedDivisor = 86.975`

2. **`slcan_service.dart`** — USB serial CAN service:
   - `enum ProtocolMode { slcan, robotell, waveshare }`
   - `SlcanService` — manages USB serial port via `usb_serial` package
   - **CANable (SLCAN):** sends `C\r` → `S5\r` → `O\r` on connect; ASCII frame format `T{8-hex-ID}{DLC}{data}\r`
   - **Robotell:** binary init `AA 55 01 [speed] [mode] [ck]`; fixed 21-byte frames `AA AA [ID:4 LE] [data:8] [DLC] ... 55 55`
   - **Waveshare:** no init; variable frames `AA [ctrl] [ID LE] [data] 55`, ctrl bit5=extended, bits3–0=DLC
   - `setPortParameters` wrapped in try-catch (CDC devices throw on baud rate set — non-fatal)
   - Exposes `frameStream` and `statusStream`

3. **`canalystii_service.dart`** — Raw USB CANalyst-II service:
   - `CanDevice` wrapper — unifies serial (`UsbDevice`) and CANalyst-II (raw USB, `int` deviceId)
   - `CanalystiiService` — MethodChannel `canalystii/methods`, EventChannel `canalystii/frames`
   - `listDevices()`, `connect(device)`, `disconnect()`
   - Type casting: use `(m['id'] as num).toInt()`, `m['extended'] == true`, `(e as num).toInt()` — StandardMessageCodec quirk

4. **`main.dart`** — UI:
   - Supercar display theme (see colour palette below)
   - App name: **KTZ** (`android:label`)
   - Connection bar: device dropdown → protocol toggle (hidden for CANalyst-II) → Connect/Disconnect button
   - Refresh button hidden; USB hotplug handled via `UsbSerial.usbEventStream`
   - `_refreshDevices()` filters out VID `0x04D8` from serial list (CANalyst-II handled separately)
   - 3×2 `MetricCard` grid: VOLTAGE, CURRENT, SPEED, SHAFT RPM, GEAR, FAULT
   - Signals card: 3×2 grid — THROTTLE CFM, BRAKE SIG, BRAKE CFM / CRUISE, HANDBRAKE
   - Fault display card: 4×2 grid — MOTOR TEMP, MCU TEMP, 12V RAIL, THROTTLE / GEAR POS, MAG CODE, 4.096V REF, 5V SUPPLY
   - Raw CAN frames table: CYCLE column header is "CYCLE (ms)", value is number only; `0x0D259CD0` and `0x0D259CE7` pinned first

## Kotlin plugin — CANalyst-II (`CanalystiiPlugin.kt`)

- **VID:** `0x04D8`, **PID:** `0x0053` (Chuangxin Tech USBCAN/CANalyst-II)
- Iterates all USB interfaces to find EP `0x02` (BULK OUT, commands) and `0x81` (BULK IN, messages)
- INIT command: 64-byte LE — command=1, acc_mask=0xFFFFFFFF, filter=1, timing0=0x01 (BTR0), timing1=0x1C (BTR1), mode=0
- START command: 64-byte LE — command=2, rest zeros
- Read loop: `bulkTransfer(inp, buf, 64, 100ms)` — buf[0]=count (1–3), then 3×21-byte messages
- Message parse: can_id(4 LE), skip timestamp(4)+time_flag(1)+send_type(1), remote(1), extended(1), dlc(1), data(dlc)
- Posts frames via `mainHandler.post { eventSink?.success(frame) }` for thread safety
- Registered in `MainActivity.kt` via `flutterEngine.plugins.add(CanalystiiPlugin())`

## Protocol reference (EC KTZ12X40030)

- **Baud rate:** 250 kbps, **byte order:** Intel (little-endian), **frame type:** extended 29-bit
- **CAN ID `0x0D259CD0`** (Instrument, 100 ms):
  - Bytes 0–1: voltage = `raw × 0.1` V
  - Bytes 2–3: current = `raw × 0.1 − 1000` A (center raw=10000 → 0 A)
  - Bytes 4–5: shaft RPM = `raw − 10000`
  - Byte 6 bits: gear_fwd(0), gear_rev(1), throttle_confirm/active-low(2), brake_signal(3), brake_confirm(4), cruise_ctrl(5), handbrake(6)
  - Byte 7: fault code (see `kFaultCodes`)
- **Speed formula:** `|shaft_rpm| / 86.975` km/h
- **CAN ID `0x0D259CE7`** (Fault display, 100 ms):
  - Byte 0: 12V rail = `raw × 5 × 0.024` V
  - Byte 1: throttle analog = `raw × 6`
  - Byte 2: gear position = `raw × 5`
  - Byte 3: magnetic code = `raw × 128`
  - Byte 4: motor temp = `raw × 2 − 128` °C
  - Byte 5: MCU temp = `raw × 2 − 128` °C
  - Byte 6: 4.096V ref = `raw × 5 × 0.012011` V
  - Byte 7: 5V supply = `raw × 2 × 0.012` V

## Colour palette — supercar display

```dart
const _cBg     = Color(0xFF080808);  // carbon black
const _cCard   = Color(0xFF0F0F0F);  // dark carbon panel
const _cBorder = Color(0xFF1E1E1E);  // carbon edge
const _cFg     = Color(0xFFF0EEE8);  // warm ivory white
const _cMuted  = Color(0xFF666666);  // platinum gray
const _cAccent = Color(0xFFC9A227);  // champagne gold
const _cValue  = Color(0xFFFFFFFF);  // pure white readout
const _cOk     = Color(0xFF00C896);  // teal green
const _cWarn   = Color(0xFFF0A500);  // deep amber
const _cErr    = Color(0xFFFF3B30);  // racing red
const _cOff    = Color(0xFF1A1A1A);  // inactive
```

- `MetricCard`: gold top-line 1px border, value text has glow shadow
- `_SectionCard`: left border 3px champagne gold, title 11px w700 letterSpacing 1.0

## Android configuration

- **Package:** `com.bhl.ktz12x40030`
- **App label:** `KTZ`
- **minSdk:** `flutter.minSdkVersion` (21)
- **targetSdk:** 34
- **USB Host:** declared in `AndroidManifest.xml` — app auto-launches when USB device is plugged in
- **Device filter:** `res/xml/device_filter.xml` — matches any USB device
- **AGP:** 8.7.3 (pinned — do not upgrade to 9.x, breaks `usb_serial` `jcenter()` dependency)
- **Gradle:** 8.10.2
- **Kotlin:** 2.1.0

## App icon

Icons live in `android/app/src/main/res/mipmap-*/ic_launcher.png`.  
Regenerate by running `gen_icon.py` (requires Pillow: `pip install Pillow`).

**Current design:** carbon black background, champagne gold rounded-rectangle border, white "aCAN" text centered in Georgia Bold.

```python
BG_COL     = (10, 10, 10)    # carbon black
BORDER_COL = (201, 162, 39)  # champagne gold
TEXT_COL   = (255, 255, 255) # pure white
FONT_PATH  = 'C:/Windows/Fonts/georgiab.ttf'  # Georgia Bold
```
