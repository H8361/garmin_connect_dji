**简体中文** | **English**

# Controlling DJI Osmo Action 4 recording from a Garmin watch — detailed design

> Goal: start a workout on the watch → the Action 4 starts recording automatically; end the workout → recording stops automatically. The watch is the only device you touch — no phone, no camera buttons.
> Date: 2026-10-26 (protocol chapter updated after implementation)
>
> **Implementation status**: the code is complete per this design (`datafield/` data
> field project + `testapp/` debug app + `shared/` protocol & client) and compiles
> under Connect IQ 9.3.0 for all 37 target devices. During implementation the
> protocol was upgraded to the **official DJI R SDK protocol** (more authoritative
> than the reverse-engineered Mimo protocol found in early research) — see
> sections 4.2/4.3. The whole chain has been verified on a real FR255 + Action 4.

---

## 1. Conclusion and recommended route

**Feasible — recommended route: develop a Connect IQ (CIQ) Data Field on the watch
that connects directly to the Action 4 over BLE (central role) and sends the
official DJI R SDK protocol commands to start/stop recording. No phone involved,
no camera modification.**

Three pillars of feasibility (all verified):

1. **Garmin already did exactly this for GoPro**: the official "GoPro® Camera
   Control" app in the Connect IQ Store (launched Aug 2024, built by Garmin) lets
   the watch start/stop recording on an action camera over BLE — proving that
   "watch BLE central ↔ action camera" is production-grade. Garmin only did GoPro,
   not DJI — hence this project.
2. **The DJI camera BLE protocol is documented and open**:
   - [datagutt/node-osmo](https://github.com/datagutt/node-osmo): TypeScript library
     explicitly supporting **Osmo Action 3/4/5** and Pocket 3 BLE control (pairing,
     connection, start/stop recording, settings).
   - [yigitkonur/lib-osmo-ble](https://github.com/yigitkonur/lib-osmo-ble): complete
     reverse-engineering docs (`PROTOCOL.md`) for the DUML-over-BLE variant.
3. **DJI open-sourced a BLE remote-control demo themselves**:
   [dji-sdk/Osmo-GPS-Controller-Demo](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo)
   (MIT), an ESP32-C6 BLE remote **supporting Osmo Action 4/5 Pro/6 and Osmo 360 —
   a single button press starts/stops recording**. This is the authoritative
   reference for the Action 4 command bytes.

---

## 2. Pre-flight checks (confirm these two before starting)

| # | Check | Method | Fallback |
|---|-------|--------|----------|
| 1 | **Does the watch support CIQ BLE central (scan/pair)?** | Open the official "GoPro® Camera Control" app page in the phone's Connect IQ Store and look at *Compatible Devices*: if your watch is listed, it has the required BLE capability | Section 10, alternative route 2 (phone relay) |
| 2 | **Camera firmware recent, Mimo not occupying the link** | Update the camera firmware; make sure the DJI Mimo phone app is not connected (the camera's BLE accepts one central at a time) | Usage habit, no workaround |

Rough BLE capability bar: the `Toybox.BluetoothLowEnergy` module exists since API
3.1.0, but the scan/pair/bond capabilities used here (`setScanState`/`pairDevice`/
`getBondedDevices`/`setConnectionStrategy`) need newer APIs (~4.2.5–5.1.0+),
i.e. 2022+ models (Fenix 7/8, Epix Gen 2/Pro, Enduro 3, Forerunner 265/965/570,
Venu 3, Instinct 2/3, MARQ Gen 2, Descent Mk3…). **Trust check #1, don't guess.**

App types allowed to use BLE (per official docs): Watch App, **Data Field**,
Widget, Glance, Background, Audio Content Provider — **Data Field is on the
list**, which is the key to this design.

---

## 3. System architecture

```
┌──────────────────────────── Garmin watch ─────────────────────────┐
│  Native sport profile (running/cycling/trail…)                     │
│   └─ Data screen hosts [DJI Cam Control data field]                │
│        ├─ timer start onStart/onTimerStart ──→ "start recording"   │
│        ├─ timer stop/exit onStop ──────────→ "stop recording"      │
│        └─ status display: link state / recording / battery;        │
│           vibration on errors                                      │
│                    │  BLE central (GATT client)                    │
└────────────────────┼───────────────────────────────────────────────┘
                     │ write fff5 (writeWithoutResponse) / fff4 notify
┌────────────────────▼───────────── DJI Osmo Action 4 ──────────────┐
│  GATT service fff0: fff3 / fff4 (pairing+response notify) /        │
│  fff5 (command downlink)                                           │
│  Protocol layer → camera MCU → start/stop recording                │
└────────────────────────────────────────────────────────────────────┘
```

A **data field** was chosen over a standalone app because a data field lives
inside the native sport profile and receives lifecycle callbacks as the workout
timer starts/stops — naturally implementing "workout starts → recording,
workout ends → stop", while keeping the native data pages and user habits.

---

## 4. Core technical points

### 4.1 Connect IQ BLE capabilities and limits

- Declare the **Bluetooth Low Energy permission** in `manifest.xml`.
- `BLE.setDelegate(delegate)` registers callbacks (one delegate per app):
  scan results, connect/disconnect, characteristic updates.
- Scanning entry: `registerScan()` / `setScanState()` (SDK-version dependent);
  scanning is **passive** and cannot be made active.
- **`registerProfile()` must be called before any GATT access** to declare the
  service/characteristic UUIDs (max 3 profiles) — this design needs one: the
  fff0 service with fff4/fff5 characteristics.
- `pairDevice(scanResult)` performs pairing; **CIQ session pairing does not
  persist across app instances** — the system-level bond does, so recover the
  device with `getBondedDevices()` (API 4.2.5+) and use
  `setConnectionStrategy()` (API 5.1.0+) for auto-reconnect. This is the single
  most important engineering detail — see 6.4.
- **The simulator is no substitute for a real device**: BLE behavior needs
  on-device iteration.

### 4.2 The official DJI "R SDK" BLE protocol (final choice, from DJI's open-source demo)

During implementation DJI's own complete protocol documentation and reference
implementation were discovered
([dji-sdk/Osmo-GPS-Controller-Demo](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo),
MIT, explicitly supporting **Osmo Action 4/5 Pro/6 and Osmo 360**), so the
initially-researched reverse-engineered Mimo DUML(0x55) protocol
(lib-osmo-ble, byte-verified only on Pocket 3) was dropped in favor of the
official protocol: no PIN pairing, formal documentation, all command bytes
available. Reference files kept in `refs/demo/`.

**GATT (official ble.c / Q&A #1)**: service `0xFFF0`; `0xFFF4` notify (camera →
watch; subscribe by writing 0x0001 to the CCCD); `0xFFF5` write (watch → camera;
with/without response, chosen per command type).

**Frame format (0xAA frame, little-endian throughout)**:

```
[0]SOF=0xAA [1..2]Ver/Length(high 6 bits version=0, low 10 bits=total frame length) [3]CmdType(bit5=response frame,bit4..0=ack type)
[4]ENC=0 [5..7]RES=0 [8..9]SEQ [10..11]CRC16(over SOF..SEQ) [12]CmdSet [13]CmdID [14..]payload [last 4]CRC32(over SOF..DATA)
```

- **CRC16: init `0x3AA3`, poly `0xA001` (reflected), no final XOR**
- **CRC32: init `0x3AA3`, poly `0xEDB88320` (reflected), no final XOR**
- Both CRC parameter sets were verified against all 10 official
  `connect_cmd_frame.txt` test frames plus the documented example frame
  (verification script `tools/validate_crc.py`)

**Key commands**:

| Function | CmdSet/CmdID | payload essentials |
|----------|--------------|--------------------|
| Connect request/response | `0x00/0x19` | 33B: device_id (watch side uses the 0x12345678 test value), mac_len=6+16B placeholder MAC, fw_version=0 (suppresses the upgrade prompt), conidx, verify_mode (1=first pair/0=already paired/2=camera's receipt), verify_data, reserved |
| Record control | `0x1D/0x03` | 9B: device_id=`0x33FF0000` (copied from the official implementation), record_ctrl (0=start/1=stop), reserved. Response is 1B ret_code |
| Key report | `0x00/0x11` | 4B: key_code (1=record key), mode=0x01, key_value=0 (short press). **A sleeping camera that receives the record key wakes up and starts recording immediately** |
| Status subscribe/push | `0x1D/0x05`, `0x1D/0x02` | subscribe push_mode=3, freq=20 (fixed 2Hz); the 38B push carries camera state (**0x03=recording**), battery, free SD, power mode (3=sleep) |
| Power mode | `0x00/0x1A` | 0=normal / 3=sleep |

**Connection handshake (four steps)**: the watch sends a connect request
(verify_mode=1 first time / 0 already paired) → the camera immediately ACKs
(ret_code) → the camera **initiates its own** connect request (verify_mode=2,
verify_data 0=allowed; device_id carries the camera model — Action 4=0xFF33) →
the watch replies with a connection response (reserved[0]=camera index, 0 for a
single camera). Camera model device_id table: Action 4=0xFF33,
Action 5 Pro=0xFF44, Osmo 360=0xFF66, Action 6=0xFF55.

**Advertisement filter (official ble.c)**: manufacturer data bytes
`[0]=0xAA, [1]=0x08, [4]=0xFA`; plus the advertised name containing "Osmo".
The Action 4's fff4 only carries 0xAA frames (the Action 5 mixes in 0x55
frames — ignore those).

### 4.3 Command byte verification results

The originally planned M1 "reverse-confirm" step was resolved directly by the
official documentation (see `refs/demo/docs/protocol_CN.md` and
`docs/protocol_data_segment_CN.md`). Only two items needed on-device
confirmation (both handled in code with fallbacks):
① the CIQ per-write limit is 20 bytes, so the 27-byte record command frame is
sent in fragments (the camera reassembles the SOF-delimited stream — works in
practice); ② reassembly of 56-byte status push notifications when the watch
MTU is small.

---

## 5. Watch-side app design (Monkey C)

### 5.1 Projects and modules

- Toolchain: VS Code + Connect IQ SDK (currently 9.x), project type **Data
  Field**, `minApiLevel` per target watch (≥ 5.1.0 recommended for the
  connection-strategy API).
- Permission: Bluetooth Low Energy.

```
source/
  CameraBLE.mc      — BleDelegate implementation: scan filter (Osmo name), pairing, state machine, auto-reconnect
  DumlCodec.mc      — DUML frame build/parse: CRC8(0x31/0xEE), CRC16(0x1021/0x496C), msgid increment
  RecordCommand.mc  — start/stop record command wrapper + response timeout resend (2x)
  CamStatus.mc      — parse CameraStatus (~10Hz) telemetry on fff4: recording flag, battery
  DJIControlField.mc— DataField body: lifecycle triggers, status UI, vibration
```

### 5.2 Skeleton code (illustrative — API details per SDK)

```monkey_c
using Toybox.BluetoothLowEnergy as BLE;
using Toybox.System;
using Toybox.WatchUi;

const SERVICE_UUID = BLE.stringToUuid("FFF0-0000-1000-8000-00805F9B34FB"); // per on-device discovery
const CHAR_FFF4 = ...;  // pairing + response notifications
const CHAR_FFF5 = ...;  // DUML command downlink (writeWithoutResponse)

class CamDelegate extends BLE.BleDelegate {
    function onScanResults(scanResults) {
        foreach (r in scanResults) {
            if (r.getLocalName().find("Osmo") != null) {
                BLE.pairDevice(r);          // first time: confirm PIN on camera screen
                BLE.setScanState(...);      // stop scanning
            }
        }
    }
    function onDeviceConnected(device)      { /* state → connected; subscribe fff4 */ }
    function onDeviceDisconnected(device)   { /* state → reconnecting; setConnectionStrategy auto-reconnect */ }
    function onCharacteristicUpdated(ch, val) {
        // fff4 notify: DUML response matching (same cmdSet/cmdId, flags 0xC0) / telemetry
    }
}

class DJIControlField extends WatchUi.DataField {
    function onStart() {  // data screen mounted: connect early (ready before the workout)
        BLE.registerProfile( fff0/fff4/fff5 );
        BLE.setDelegate(new CamDelegate());
        _reconnectOrScan();
    }
    function onTimerStart() {              // ★ workout timer starts → camera starts recording
        _sendWithRetry(RecordCommand.start());
        WakeVibe / refresh status;
    }
    function onTimerStop() {               // timer stops → camera stops recording
        _sendWithRetry(RecordCommand.stop());
    }
    function onStop(session) {             // save & exit: ensure stop was sent
        _flushStopIfPending();
    }
    // pause/resume policy configurable: onTimerPause → stop recording (new file), onTimerResume → record again
}
```

### 5.3 Lifecycle and timing

| Watch action | Data field callback | Camera | Notes |
|---|---|---|---|
| Enter sport mode on this field page | `onStart()` | — | connect now (not at timer start) |
| Press "start" (timer starts) | `onTimerStart()` | **start recording** | BLE already connected; command latency tens to hundreds of ms, acceptable for editing alignment |
| Pause timer | `onTimerPause()` | (configurable) stop recording | Action 4 resumes into a new file |
| Resume timer | `onTimerResume()` | (configurable) record again | new file |
| Stop & save | `onTimerStop()`/`onStop()` | **stop recording** | double insurance: onStop flushes a stop |

### 5.4 Reconnection and pairing persistence (the most important engineering point)

- First pairing: done in the data field or via a one-shot Watch App (easier UI):
  scan → `pairDevice` → confirm PIN on the camera screen → bond complete.
- Every workout after: `onStart()` calls `getBondedDevices()` to find the Action 4
  and connect directly; combined with `setConnectionStrategy()` for system-level
  auto-reconnect; if unreachable (camera off/empty battery) the field shows a
  fault state and vibrates once, **never blocking workout recording**.
- All BLE calls are wrapped in exception protection; any camera-side failure only
  affects recording, never workout data.

---

## 6. Camera-side preparation checklist

1. Update the camera firmware to the latest.
2. First pairing pops a confirmation/PIN on the camera screen — one-time.
3. Settings: set **auto power-off to "never" or the longest** (don't sleep during
   BLE use); for long workouts power the camera from a USB power bank; set
   recording parameters (resolution/fps/stabilization) in advance — the watch
   only handles start/stop.
4. Make sure the Mimo app is not connected to the camera (BLE single central).
5. Storage/battery self-checks: the field can display battery from telemetry.

---

## 7. Development milestones

| Phase | Content | Output | Estimate |
|-------|---------|--------|----------|
| M0 | Environment & feasibility self-check: watch on the GoPro app compatibility list; install CIQ SDK; sideload "Hello Data Field" | custom data field shows on watch | 0.5 day |
| M1 | ~~Protocol verification~~ **done**: switched to the DJI official R SDK protocol; all command bytes from official docs; CRC verified with 11 official test frames (`refs/validate_crc.py`) | `refs/demo/` + implementation | 0 (done) |
| M2 | Watch-side BLE: profile registration, scan/pair/bond reconnect, fff5 writes / fff4 subscribe | **implemented** (`CameraClient.mc`), pending device verification | coded |
| M3 | Protocol codec + record commands + timeout resend + status push parsing | **implemented** (`DjiProtocol.mc`), pending device verification | coded |
| M4 | Data field integration: onTimerStart/onTimerStop triggers, status UI, vibration, pause policy, error paths (camera off/disconnected/empty) | complete experience, invisible during workouts | 1–2 days |
| M5 | Long-run field testing (weeks of real workouts), edge polishing; optional Connect IQ Store release | stable | 1 week (passive observation) |

---

## 8. Test and verification points

- M1 packet-capture chain: Android developer options → "Enable Bluetooth HCI
  snoop log" → Wireshark + LTK decryption (or nRF Sniffer).
- Every command needs **response matching** (flags 0xC0 reply) rather than
  "wrote it and hoped"; 500ms timeout, resend twice.
- On-device test matrix: cold first pairing / second run reuses bond / wake from
  camera sleep / mid-workout disconnect+reconnect / empty camera battery / first
  connect after watch reboot / multi-segment pause-resume.
- Acceptance: ≤1s from pressing "start" to the camera recording; ≤1s on stop;
  10 workouts with 0 missed triggers.

## 9. Risks and mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Watch model lacks BLE central | Route 1 infeasible | Section 2 self-check first; otherwise fallback route 2 |
| Action 4 protocol details differ from verified models (Pocket 3) | Commands invalid | M1 on-device verification + DJI official demo source as authority (Action 4 is in its supported list) |
| CIQ pairing not persistent across instances; background connection throttled by OS scheduling | Re-pair every workout / can't connect | getBondedDevices + setConnectionStrategy; connect early in onStart; follow the mature GoPro third-party data field pattern (Store already has one) |
| BLE MTU/write length limits | Frames can't be sent | start/stop frames are only ~13 bytes (empty payload), far below MTU — no risk; long frames only during pairing |
| Camera sleep / auto power-off | Can't connect at workout start | camera setting: disable auto power-off; field status display |

## 10. Alternative routes

- **Route 2 (fallback): phone relay**. The watch data field uses
  `Communications.makeWebRequest()` → a small self-built phone app (or Tasker)
  listening on a LAN port → the phone sends DUML commands to the Action 4 over
  BLE (same protocol; porting node-osmo logic is much easier to debug on the
  phone). The watch→phone HTTP hop through the Garmin Connect Mobile proxy to a
  "phone LAN IP:port" is a heavily community-verified pattern (the Home
  Assistant watch integration works this way). Downsides: phone required during
  workouts, two codebases. Upside: no BLE requirements on the watch model.
- **Route 3 (no linkage, lowest cost): build the BLE remote from DJI's official
  ESP32-C6 Demo** (tens of RMB, single-click record/stop). But it cannot sense
  the watch's workout start/stop, failing the "watch only" core requirement —
  hardware fallback only.
- Voice control ("start recording"): impractical while running, listed for
  completeness.

## 11. References

- Garmin official GoPro remote app (existence proof + compatibility lookup):
  https://apps.garmin.com/en-US/apps/b6474aef-4b36-46ea-b7e5-6e8612b50e9d
- DC Rainmaker review: https://www.dcrainmaker.com/2024/08/garmin-watch-gopro-camera-control.html
- CIQ BluetoothLowEnergy API: https://developer.garmin.com/connect-iq/api-docs/Toybox/BluetoothLowEnergy.html
- DJI official BLE remote demo (includes Action 4, MIT): https://github.com/dji-sdk/Osmo-GPS-Controller-Demo
- DUML-over-BLE reverse-engineering doc: https://github.com/yigitkonur/lib-osmo-ble/blob/main/PROTOCOL.md
- Action 3/4/5 BLE control library (TS): https://github.com/datagutt/node-osmo
- DJI protocol capture & Wireshark dissector: https://github.com/xaionaro/reverse-engineering-dji
