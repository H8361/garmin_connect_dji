**English** | [简体中文](README.zh-CN.md)

# garmin-connect-dji

**Control a DJI Osmo Action camera from your Garmin watch** — recording auto-starts when your workout begins and auto-stops when it ends. Everything happens on the watch: no phone, no camera buttons.

> A Connect IQ data field that lets Garmin watches start/stop recording on DJI Osmo Action cameras over Bluetooth LE. Verified end-to-end on Forerunner 255 + Osmo Action 4.

Design notes (Chinese): [实现方案.md](实现方案.md)

---

## Features

- **Auto-link**: connects to the camera when you enter a sport (cycling/running…); timer start → recording starts; timer stop → recording stops
- **Pause-proof**: pausing the workout does NOT interrupt recording — no fragment files
- **Live status**: REC dot, recording time, camera battery and free SD space on the field
- **Acknowledged commands**: every record command waits for the camera's response, auto-retries, vibrates on result
- **Auto-reconnect**: re-scans and reconnects after dropouts; wakes a sleeping camera with the "record key" event

## How it works

```
┌──────────────────────────── Garmin watch ─────────────────────────┐
│  Native sport profile (cycling/running…)                           │
│   └─ Data field [DJI Cam Control]                                  │
│        ├─ AppBase shell: owns the connection lifecycle             │
│        ├─ View: timer events drive record commands + 1 Hz drawing  │
│        └─ Heartbeat: compute() on data fields, Timer in apps       │
│                    │ BLE central (GATT client)                     │
└────────────────────┼───────────────────────────────────────────────┘
                     │ write FFF5 (commands) / receive FFF4 (acks, status)
┌────────────────────▼───────────── DJI Osmo Action 4 ──────────────┐
│  GATT service FFF0                                                 │
│  DJI R SDK protocol (0xAA frames): 0019 handshake → 1D03 record    │
│  control → 1D02 status push                                        │
└────────────────────────────────────────────────────────────────────┘
```

The protocol is the **official DJI R SDK BLE protocol** — the same one used by DJI's
open-source [Osmo-GPS-Controller-Demo](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo)
remote. Frame layout and CRC parameters are verified byte-for-byte against DJI's
official test vectors.

## Supported devices

- **Watch (verified)**: Forerunner 255 (fw 29.05 / CIQ 6.0.4)
- **Watch (should work)**: 2022+ models with CIQ BLE central — Fenix 7/8, Epix 2,
  Enduro 3, FR165/265/570/955/965/970, Venu 3/4, vivoactive 5, Instinct 3, MARQ 2,
  Descent Mk3 (39 devices in the manifest, all build-verified)
- **Camera**: Osmo Action 4 (0xFF33); the protocol also covers Action 5 Pro (0xFF44),
  Action 6 (0xFF55) and Osmo 360 (0xFF66)

To check your watch: open the official
[GoPro Camera Control](https://apps.garmin.com/en-US/apps/b6474aef-4b36-46ea-b7e5-6e8612b50e9d)
app page in the Connect IQ Store and look at "Compatible Devices".

## Installation

1. Download `DJIFIELD.PRG` from [Releases](../../releases) and copy it to the watch's
   USB drive under `GARMIN\APPS\` (**keep the 8.3 filename**, eject safely);
2. Long-press UP → Activities & Apps → Cycling → Activity Options → Data Screens →
   add the **DJI Cam Control** field;
3. Power on the camera (wireless connection ON, screen awake, phone Mimo disconnected);
4. Start the workout timer → the camera starts recording; stop/save → recording stops.
   **Pausing the timer does NOT stop recording.**

The field page shows REC dot + recording time, camera battery and free SD space.
Vibration patterns confirm command results.

## Building from source

Requirements: [Connect IQ SDK 9.3.0+](https://developer.garmin.com/connect-iq/sdk/)
(with device packs), JDK 11+, OpenSSL. A bundled `jdk/` is included for Windows
(build scripts use it automatically).

```bat
:: Windows
build.bat              :: defaults to fr255, output in bin\
build.bat fenix7       :: another device
```

```bash
# Linux / macOS / Git Bash
./build.sh
```

Raw command:

```bash
sdk/bin/monkeyc -f datafield/monkey.jungle -d fr255 -y developer_key.der -w -o bin/DJIFIELD.PRG
```

**The developer key must be RSA 4096-bit** (generation and DER conversion in the
pitfalls list below). Build artifacts are distributed via GitHub Releases; `bin/`
is gitignored.

### Simulator

```bash
sdk/bin/connectiq.bat                                  :: start the simulator
sdk/bin/monkeydo bin/DJITEST.PRG fr255                 :: load the test app
```

Text rendering in the simulator requires downloading the device pack in SDK
Manager (fonts).

## FR255 pitfalls (hard-won — read before any Garmin BLE project)

Four FR255-specific pitfalls were found while building this project. **Every one
of them fails silently** (no error message, nothing works):

| # | Pitfall | Symptom | Fix |
|---|---------|---------|-----|
| 1 | **PRG filename must be 8.3** (base name ≤ 8 chars) | Long-named PRGs copied to `GARMIN/APPS/` are **silently deleted** on reconnect — not installed, no error | Output short names like `DJITEST.PRG` |
| 2 | **Developer key must be RSA 4096-bit** | Since 2025-Q2 firmware, sideloaded apps signed with 2048-bit keys fail the new signature check — silently rejected | `openssl genrsa -out key.pem 4096` |
| 3 | **`Timer.start()` takes only 3 arguments** and the callback is **parameter-less** | A 4-arg call throws `Too Many Arguments Error`; if the flag is set before the call, the timer silently dies + unguarded paths crash | `start(method, ms, true)`; `onTick()` without params |
| 4 | **A data field's entry class must be an AppBase shell** | Using the DataField class directly as the entry → `Failed to start CIQ Application / Unexpected Type Error` (empty stack) | AppBase shell + `getInitialView()` returns the field view; use `compute()` instead of Timer for the heartbeat |

**Crash logs are the first piece of debugging evidence**: `CIQ_LOG.YML` on the
watch's USB drive (YAML with a symbolicated stack), translated to source locations
with `tools/symbolicate.py`. This project's crash was only located with it (the
first three rounds of blind fixes went the wrong way).

Two more device-db quirks: data fields **have no `Toybox.Timer` permission** (the
heartbeat is driven by `compute()`); the simulator's fr255 font resources come
with the device pack (community-extracted packs lack fonts — the simulator
crashes on any text rendering, the real watch is unaffected).

## Known limitations

- The camera must be confirmed once on its own screen during pairing (official
  handshake); afterwards it reconnects silently
- A camera asleep for >30 minutes cannot be woken via BLE (official limitation);
  power it on manually before the workout
- GPS dashboard push (0017) not implemented: recordings carry no GPS dashboard
  data (the protocol is ready — PRs welcome)
- With multiple cameras in range, connects to the first one found

## Repository layout

```
datafield/   Production data field (App shell + view)
testapp/     Debug app (manual control, link verification)
shared/      Protocol codec (DjiProtocol) + camera client (CameraClient)
tools/       Icon generator / crash-log symbolication / CRC tests + vectors
build.bat    Windows one-shot build
build.sh     Linux/macOS/Git Bash one-shot build
实现方案.md   Design notes (Chinese)
```

## Credits & references

- [DJI Osmo-GPS-Controller-Demo](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo) —
  DJI's official open-source remote demo, the authoritative protocol source (MIT)
- [datagutt/node-osmo](https://github.com/datagutt/node-osmo) —
  Osmo-series BLE control library, cross-validation
- [yigitkonur/lib-osmo-ble](https://github.com/yigitkonur/lib-osmo-ble) —
  DUML-over-BLE protocol documentation
- Garmin
  [FieldTimerEvents](https://developer.garmin.com/connect-iq/sample-code/) /
  [NordicThingy52](https://developer.garmin.com/connect-iq/sample-code/) samples —
  data field structure and BLE central patterns
- [GoPro Camera Control](https://apps.garmin.com/en-US/apps/b6474aef-4b36-46ea-b7e5-6e8612b50e9d) —
  Garmin's official GoPro remote (precedent for watch→BLE→action camera)

## License

[MIT](LICENSE)
