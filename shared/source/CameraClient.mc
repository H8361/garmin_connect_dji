// ============================================================================
// CameraClient.mc — Action 4 相机连接管理与命令收发
//
// 链路: BLE central → 服务 FFF0 → 订阅 FFF4 通知 / 写 FFF5 (官方 demo ble.c)
// 握手: 0019 连接请求 → 相机应答 → 相机反向请求(verify_mode=2) → 回应答
// 命令: 1D03 拍录控制 (开始/停止), 0011 按键上报 (休眠唤醒+拍摄)
// 状态: 1D05 订阅后相机以 2Hz 推送 1D02 (含录制中标志/电量/剩余容量)
//
// 上层监听对象需实现 (duck typing):
//   onCameraState(state as Number)            连接状态变化
//   onCameraStatus(status as Dictionary)      相机状态推送 (1D02)
//   onRecordResult(success as Boolean, msg)   录像控制命令结果
// ============================================================================

import Toybox.BluetoothLowEnergy;
import Toybox.System;
import Toybox.Timer;
import Toybox.Application;
import Toybox.Attention;
import Toybox.Lang;

// ---- 相机连接状态 ----
const CAM_IDLE     = 0; // 未启动
const CAM_SCANNING = 1; // 扫描相机中
const CAM_CONNECTING = 2; // 配对/连接中
const CAM_BLE_READY  = 3; // BLE 已连接, 协议握手中
const CAM_READY      = 4; // 协议握手完成, 可发命令
const CAM_FAILED     = 5; // 失败 (相机不在/配对失败/握手超时)

// ---- GATT (官方 demo: 服务 0xFFF0, 通知 0xFFF4, 写 0xFFF5) ----
const DJI_UUID_SERVICE = "0000FFF0-0000-1000-8000-00805F9B34FB";
const DJI_UUID_NOTIFY  = "0000FFF4-0000-1000-8000-00805F9B34FB";
const DJI_UUID_WRITE   = "0000FFF5-0000-1000-8000-00805F9B34FB";

// CIQ 写类型注意: WRITE_TYPE_WITH_RESPONSE(0)=带响应, WRITE_TYPE_DEFAULT(1)=无响应
const DJI_WRITE_RSP = BluetoothLowEnergy.WRITE_TYPE_WITH_RESPONSE;
const DJI_WRITE_NORSP = BluetoothLowEnergy.WRITE_TYPE_DEFAULT;

// 单次 GATT 写上限 (超过抛 InvalidRequestException, 需分片)
const BLE_WRITE_MTU_LIMIT = 20;

// 命令响应超时/重发参数
const CMD_TIMEOUT_MS = 2000;
const CMD_MAX_RETRIES = 2;

// 广播名过滤前缀 (辅助过滤, 与厂商数据过滤取或)
const DJI_ADV_NAME_PREFIX = "Osmo";

// 相机状态推送订阅开关。
// FR255 固件 29.05 实测: 订阅后相机推送的 56 字节 1D02 状态帧会触发
// CIQ 蓝牙栈原生崩溃 (IQ !), 故默认关闭。录像控制不依赖状态推送,
// 仅 UI 上的电量/录制时长显示会缺失。其他机型可改回 true。
const ENABLE_STATUS_SUB = true;

// 详细日志开关 (每条状态推送 5 行日志, 长时间运动建议关闭; 排障时打开)
const VERBOSE_LOG = false;

// 判决实验2: 跳过 0019 握手, 连接后直接盲发 1D03 (验证相机是否强制要求握手)
const NO_HANDSHAKE_MODE = false; // 定时器修复后, 完整握手可用且应答可靠

// 就绪后关闭通知 (CCCD=0): FR255 收到相机 56B 推送会原生崩溃,
// 关闭后相机的推送/应答由蓝牙栈底层丢弃, 命令变为"发射后不管" (相机仍执行)。
// 握手阶段仍需要通知, 故在 READY 后才关闭。
const DISABLE_NOTIFY_AFTER_READY = false;

// 判决实验: true = 通知只记录 RX 日志、完全跳过解析/分发 (隔离崩溃层)
const RX_ONLY_MODE = false;

class CameraDelegate extends BluetoothLowEnergy.BleDelegate {

    var mClient;

    function initialize(client) {
        BluetoothLowEnergy.BleDelegate.initialize();
        mClient = client;
    }

    function onProfileRegister(uuid, status) {
        mClient.onProfileRegistered(status);
    }

    function onScanResults(results) {
        mClient.onScanResults(results);
    }

    function onScanStateChange(state, status) {
        mClient.onScanStateChange(state, status);
    }

    function onConnectedStateChanged(device, state) {
        mClient.onConnectionState(device, state);
    }

    function onCharacteristicChanged(characteristic, value) {
        mClient.onNotify(characteristic, value);
    }

    function onCharacteristicWrite(characteristic, status) {
        // 写完成回执: 驱动写队列发下一片
        mClient.onWriteDone(status);
    }

    function onDescriptorWrite(descriptor, status) {
        // CCCD 描述符写完成回执
        mClient.onDescriptorWriteDone(status);
    }

    function onEncryptionStatus(device, status) {
        // 相机链路不加密, 无需处理
    }
}

class CameraClient {

    // ---- 基础 ----
    var mListener;
    var mDelegate;
    var mState;
    var mStarted;
    var mLog;

    // ---- BLE ----
    var mUuidSvc;
    var mUuidNoti;
    var mUuidWrite;
    var mUuidCccd;
    var mProfileOk;
    var mScanning;
    var mDevice;
    var mNotifyChar;
    var mWriteChar;

    // ---- 协议 ----
    var mParser;
    var mSeq;
    var mPending;      // 等响应的命令 {:kind,:seq,:retries,:deadline,:bytes,:writeType,:name}
    var mSendQueue;    // 待写队列 (已按 20B 分片) {:bytes,:writeType}
    var mLastSendAt;
    var mWriteBusy;    // GATT 同一时间只允许一个未完成写操作

    // ---- 相机状态 ----
    var mRecording;
    var mCameraStatus;
    var mConnectingDeadline; // CONNECTING 状态超时兜底

    // ---- 周期心跳 (两种驱动方式) ----
    // watch-app: 内部 Timer (100ms); datafield: FR255 禁用 Timer,
    // 由视图的 compute(info) (系统 1Hz) 调 onCompute() 驱动
    var mTimer;
    var mTimerOn;
    var mUseTimer;

    function initialize(listener, useTimer) {
        mListener = listener;
        mUseTimer = useTimer;
        mState = CAM_IDLE;
        mStarted = false;
        mProfileOk = false;
        mScanning = false;
        mDevice = null;
        mNotifyChar = null;
        mWriteChar = null;
        mParser = new DjiFrameParser();
        mSeq = 1;
        mPending = null;
        mSendQueue = [];
        mLastSendAt = 0;
        mWriteBusy = false;
        mRecording = false;
        mCameraStatus = null;
        mConnectingDeadline = 0;
        mTimerOn = false;
        if (mUseTimer) {
            mTimer = new Timer.Timer();
        }
        mScanLogged = 0;
        mLoggedKeys = [];
        mTickMarked = false;
        mRxLogged = 0;
        mLog = [];
        mDelegate = new CameraDelegate(self);
    }

    // =========================================================================
    // 对上层暴露的接口
    // =========================================================================

    // 启动: 注册 profile → 尝试重连已绑定相机 → 否则扫描
    // 可重复调用 (幂等); 失败后可再次调用重试
    function start() {
        if (mStarted) {
            return;
        }
        mStarted = true;
        try {
            BluetoothLowEnergy.setConnectionStrategy(BluetoothLowEnergy.CONNECTION_STRATEGY_DEFAULT);
        } catch (e) {
            log("setConnectionStrategy 不可用: " + e.getErrorMessage());
        }
        mUuidSvc = BluetoothLowEnergy.stringToUuid(DJI_UUID_SERVICE);
        mUuidNoti = BluetoothLowEnergy.stringToUuid(DJI_UUID_NOTIFY);
        mUuidWrite = BluetoothLowEnergy.stringToUuid(DJI_UUID_WRITE);
        mUuidCccd = BluetoothLowEnergy.cccdUuid();
        BluetoothLowEnergy.setDelegate(mDelegate);
        setState(CAM_CONNECTING);
        try {
            // profile 声明要访问的远端服务/特征; GATT 操作仅限已注册项
            BluetoothLowEnergy.registerProfile({
                :uuid => mUuidSvc,
                :characteristics => [
                    { :uuid => mUuidNoti, :descriptors => [mUuidCccd] },
                    { :uuid => mUuidWrite }
                ]
            });
        } catch (e) {
            log("profile 注册异常: " + e.getErrorMessage());
            setState(CAM_FAILED);
        }
    }

    // 重新扫描/重连 (测试 App 的手动重连入口)
    function reconnect() {
        stopScan();
        mPending = null;
        mSendQueue = [];
        if (mProfileOk) {
            tryReconnectOrScan();
        } else {
            mStarted = false;
            start();
        }
    }

    // 退出时清理
    function close() {
        stopScan();
        stopTimer();
        mStarted = false;
        mProfileOk = false;
        mNotifyChar = null;
        mWriteChar = null;
        mDevice = null;
    }

    // 开始录像。相机休眠时改发拍录键 (0011): 唤醒 + 立即开始拍摄
    // 返回 false = 当前未就绪, 命令未发出
    function startRecording() as Boolean {
        if (mState != CAM_READY) {
            log("未就绪, 忽略开始录像");
            return false;
        }
        if (isCameraAsleep()) {
            log("相机休眠, 发拍录键唤醒+拍摄");
            return sendCommand(0x00, DJI_CMD_KEY_REPORT,
                djiBuildKeyPayload(0x01, 0x0000), :key, "wake+record", true);
        }
        return sendCommand(DJI_CMDSET_CAMERA, DJI_CMD_RECORD,
            djiBuildRecordPayload(true), :record, "record-start", true);
    }

    // 停止录像。休眠中的相机已停止录制, 无需发送
    function stopRecording() as Boolean {
        if (mState != CAM_READY) {
            log("未就绪, 忽略停止录像");
            return false;
        }
        if (!NO_HANDSHAKE_MODE && isCameraAsleep()) {
            log("相机休眠, 无需停止");
            return true;
        }
        return sendCommand(DJI_CMDSET_CAMERA, DJI_CMD_RECORD,
            djiBuildRecordPayload(false), :record, "record-stop", false);
    }

    function getState() as Number {
        return mState;
    }

    function isRecording() as Boolean {
        return mRecording;
    }

    function getCameraStatus() as Dictionary or Null {
        return mCameraStatus;
    }

    // =========================================================================
    // BLE 事件 (由 CameraDelegate 转发)
    // =========================================================================

    function onProfileRegistered(status) {
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            log("profile 注册失败 status=" + status);
            setState(CAM_FAILED);
            return;
        }
        mProfileOk = true;
        log("profile 注册成功");
        tryReconnectOrScan();
    }

    function tryReconnectOrScan() {
        // 1) 系统级已绑定的相机: 直接重新配对连接 (getBondedDevices 返回 ScanResult)
        var found = null;
        try {
            var it = BluetoothLowEnergy.getBondedDevices();
            for (var sr = (it == null ? null : it.next()); sr != null; sr = it.next()) {
                if (isDjiCamera(sr)) {
                    found = sr;
                    break;
                }
            }
        } catch (e) {
            log("getBondedDevices 异常: " + e.getErrorMessage());
        }
        if (found != null) {
            log("发现已绑定相机, 重连");
            setState(CAM_CONNECTING);
            try {
                mDevice = BluetoothLowEnergy.pairDevice(found);
                armConnectingTimeout();
                return;
            } catch (e) {
                log("重连配对失败: " + e.getErrorMessage());
            }
        }
        startScan();
    }

    function startScan() {
        if (mScanning) {
            return;
        }
        mScanning = true;
        mScanLogged = 0;
        mLoggedKeys = [];
        mTickMarked = false;
        mRxLogged = 0;
        setState(CAM_SCANNING);
        try {
            BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
            log("扫描相机中...");
        } catch (e) {
            log("扫描启动失败: " + e.getErrorMessage());
            mScanning = false;
            setState(CAM_FAILED);
        }
    }

    function stopScan() {
        if (mScanning) {
            mScanning = false;
            try {
                BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
            } catch (e) {
            }
        }
    }

    function onScanStateChange(state, status) {
        if (state == BluetoothLowEnergy.SCAN_STATE_OFF && mScanning && status != BluetoothLowEnergy.STATUS_SUCCESS) {
            log("扫描异常停止");
        }
    }

    // 相机识别: 厂商数据字节 0/1/4 = AA/08/FA (官方 demo 过滤规则), 辅以广播名
    function isDjiCamera(sr) as Boolean {
        var name = null;
        try {
            name = sr.getDeviceName();
        } catch (e) {
        }
        if (name != null && name.find(DJI_ADV_NAME_PREFIX) != null) {
            return true;
        }
        try {
            var it = sr.getManufacturerSpecificDataIterator();
            for (var entry = (it == null ? null : it.next()); entry != null; entry = it.next()) {
                var raw = entry.get(:data);
                if (raw != null) {
                    // 实测 CIQ: 公司ID单列为 :companyId(0x08AA), :data 不含公司ID,
                    // 相机广播数据 = 14 00 FA ... (stripped 布局)
                    // 两种布局都检查:
                    //   含公司ID:  data[0]=AA, data[1]=08, data[4]=FA  (官方 demo 布局)
                    //   不含公司ID: companyId=0x08AA 且 data[2]=FA     (本机实测布局)
                    var n = raw.size();
                    var hit = false;
                    if (n >= 5) {
                        var d0 = raw.decodeNumber(Lang.NUMBER_FORMAT_UINT8, { :offset => 0 });
                        var d1 = raw.decodeNumber(Lang.NUMBER_FORMAT_UINT8, { :offset => 1 });
                        var d4 = raw.decodeNumber(Lang.NUMBER_FORMAT_UINT8, { :offset => 4 });
                        if (d0 == 0xAA && d1 == 0x08 && d4 == 0xFA) {
                            hit = true;
                        }
                    }
                    if (!hit && n >= 3) {
                        var cid = entry.get(:companyId);
                        var d2 = raw.decodeNumber(Lang.NUMBER_FORMAT_UINT8, { :offset => 2 });
                        if (cid != null && cid == 0x08AA && d2 == 0xFA) {
                            hit = true;
                        }
                    }
                    if (hit) {
                        return true;
                    }
                }
            }
        } catch (e) {
        }
        return false;
    }

    var mScanLogged;   // 诊断: 已记录的扫描结果数
    var mLoggedKeys;   // 诊断: 已记录的 (名称/rssi) 去重键

    // 诊断: 公司ID转 4 位 hex
    function mfgHexHex2(v as Number) as String {
        var digits = "0123456789ABCDEF";
        var s = "";
        for (var i = 0; i < 4; i++) {
            var nib = (v >> (12 - i * 4)) & 0x0F;
            s = s + digits.substring(nib, nib + 1);
        }
        return s;
    }

    // 诊断: 厂商数据前 6 字节转 hex
    function mfgHex(raw) as String {
        var digits = "0123456789ABCDEF";
        var s = "";
        if (raw != null) {
            var bn = raw.size() > 6 ? 6 : raw.size();
            for (var i = 0; i < bn; i++) {
                var b = raw.decodeNumber(Lang.NUMBER_FORMAT_UINT8, { :offset => i });
                s = s + digits.substring((b >> 4) & 0x0F, ((b >> 4) & 0x0F) + 1)
                    + digits.substring(b & 0x0F, (b & 0x0F) + 1);
            }
        }
        return s;
    }

    function onScanResults(results) {
        if (!mScanning) {
            return;
        }
        try {
            for (var sr = (results == null ? null : results.next()); sr != null; sr = results.next()) {
                // 诊断: 记录前 15 个广播 (名称+信号+厂商数据原始字节, 去重)
                if (mScanLogged < 15) {
                    var nm = "?";
                    try {
                        var n = sr.getDeviceName();
                        if (n != null) { nm = n; }
                    } catch (e2) {
                    }
                    var key = nm + "/" + sr.getRssi();
                    var seenKey = false;
                    var kn = mLoggedKeys.size();
                    for (var k = 0; k < kn; k++) {
                        if (mLoggedKeys[k].equals(key)) {
                            seenKey = true;
                            break;
                        }
                    }
                    if (!seenKey) {
                        mLoggedKeys.add(key);
                        mScanLogged = mScanLogged + 1;
                        var info = "rssi=" + sr.getRssi();
                        try {
                            var it2 = sr.getManufacturerSpecificDataIterator();
                            for (var en = (it2 == null ? null : it2.next()); en != null; en = it2.next()) {
                                var cid = en.get(:companyId);
                                var cidHex = "";
                                if (cid != null) {
                                    cidHex = "0x" + mfgHexHex2(cid);
                                }
                                info = info + " mfg" + cidHex + "=" + mfgHex(en.get(:data));
                            }
                        } catch (e3) {
                        }
                        log("扫描到: " + nm + " " + info);
                    }
                }
                if (isDjiCamera(sr)) {
                    stopScan();
                    setState(CAM_CONNECTING);
                    log("发现相机, 配对中");
                    try {
                        mDevice = BluetoothLowEnergy.pairDevice(sr);
                        if (mDevice == null) {
                            log("pairDevice 返回 null");
                            setState(CAM_FAILED);
                        } else {
                            armConnectingTimeout();
                        }
                    } catch (e) {
                        log("配对异常: " + e.getErrorMessage());
                        setState(CAM_FAILED);
                    }
                    break;
                }
            }
        } catch (e) {
            log("扫描结果处理异常: " + e.getErrorMessage());
        }
    }

    function onConnectionState(device, state) {
        try {
            onConnectionStateInner(device, state);
        } catch (e) {
            log("连接状态回调异常: " + e.getErrorMessage());
        }
    }

    function onConnectionStateInner(device, state) {
        if (state == BluetoothLowEnergy.CONNECTION_STATE_CONNECTED) {
            mDevice = device;
            Application.Storage.setValue("everPaired", true);
            setState(CAM_BLE_READY);
            if (!setupCharacteristics()) {
                log("特征获取失败");
            }
        } else if (state == BluetoothLowEnergy.CONNECTION_STATE_DISCONNECTED) {
            log("BLE 断开");
            mNotifyChar = null;
            mWriteChar = null;
            mPending = null;
            mSendQueue = [];
            stopTimer();
            if (mState == CAM_BLE_READY || mState == CAM_READY) {
                // 运动中异常断开 (相机被唤醒/超距): 自动重连
                setState(CAM_CONNECTING);
                tryReconnectOrScan();
            }
        } else if (state == BluetoothLowEnergy.CONNECTION_STATE_REJECTED) {
            log("连接被拒绝 (安全校验)");
            setState(CAM_FAILED);
        }
    }

    // 连接建立后: 拿特征 → 订阅通知 → 发协议连接请求
    function setupCharacteristics() as Boolean {
        if (mDevice == null) {
            return false;
        }
        try {
            var svc = mDevice.getService(mUuidSvc);
            log("getService 完成");
            if (svc == null) {
                log("FFF0 服务不存在");
                return false;
            }
            mNotifyChar = svc.getCharacteristic(mUuidNoti);
            mWriteChar = svc.getCharacteristic(mUuidWrite);
            log("特征查找完成: fff4=" + (mNotifyChar != null) + " fff5=" + (mWriteChar != null));
            if (mNotifyChar == null || mWriteChar == null) {
                log("FFF4/FFF5 特征不存在");
                return false;
            }
            if (NO_HANDSHAKE_MODE) {
                // 跳过握手实验: 不订阅通知、不发 0019, 直接进入"可发命令"状态
                log("NO_HANDSHAKE: 跳过握手, 直接就绪");
                setState(CAM_READY);
                return true;
            }
            // 订阅 fff4 通知: 写 CCCD = 0x0001 (单独捕获, 不阻断握手)
            log("查找 CCCD...");
            var cccd = mNotifyChar.getDescriptor(mUuidCccd);
            log("CCCD: " + (cccd != null));
            if (cccd != null) {
                try {
                    // 官方写法 (NordicThingy52 示例): ByteArray 字面量
                    cccd.requestWrite([0x01, 0x00]b);
                    mWriteBusy = true; // GATT 忙: CCCD 完成回调后由 pumpQueue 发送连接请求
                    log("CCCD 订阅请求已发");
                } catch (e2) {
                    log("CCCD 写入异常: " + e2.getErrorMessage());
                }
            }
            // 协议握手: 首次配对 verify_mode=1 (相机弹窗确认), 之后 0
            var everPaired = (Application.Storage.getValue("everPaired") == true);
            log("构造连接请求...");
            var seq = nextSeq();
            var frame = djiBuildFrame(0x00, DJI_CMD_CONNECT, DJI_CMD_WAIT_RESULT,
                djiBuildConnectPayload(everPaired ? 0 : 1, 0x0000), seq);
            mPending = {
                :kind => :connect, :seq => seq, :retries => CMD_MAX_RETRIES,
                :deadline => System.getTimer() + 4000,
                :bytes => frame, :writeType => DJI_WRITE_RSP, :name => "connect"
            };
            enqueueFrame(frame, DJI_WRITE_RSP);
            log("连接请求已入队 (CCCD 写完成后发送)");
            return true;
        } catch (e) {
            log("setup 异常: " + e.getErrorMessage());
            return false;
        }
    }

    // =========================================================================
    // 数据收发
    // =========================================================================

    var mRxLogged;

    function onNotify(characteristic, value) {
        // RX 诊断: 记录前 10 条通知的原始字节
        if (mRxLogged < 30) {
            try {
                var digits = "0123456789ABCDEF";
                var rn = value.size() > 16 ? 16 : value.size();
                var hexs = "";
                for (var i = 0; i < rn; i++) {
                    var b = value.decodeNumber(Lang.NUMBER_FORMAT_UINT8, { :offset => i });
                    hexs = hexs + digits.substring((b >> 4) & 0x0F, ((b >> 4) & 0x0F) + 1)
                        + digits.substring(b & 0x0F, (b & 0x0F) + 1);
                }
                mRxLogged = mRxLogged + 1;
                log("RX[" + value.size() + "]: " + hexs + (value.size() > 16 ? "..." : ""));
            } catch (e0) {
                log("RX 诊断异常: " + e0.getErrorMessage());
                mRxLogged = mRxLogged + 1;
            }
        }
        var frames = [];
        try {
            frames = mParser.addBytes(value);
        } catch (e) {
            log("解析异常: " + e.getErrorMessage());
            return;
        }
        var cnt = frames.size();
        for (var i = 0; i < cnt; i++) {
            var fr = frames[i];
            if (VERBOSE_LOG) {
                log("解析帧: cmd=" + fr.get(:cmdSet) + "/" + fr.get(:cmdId)
                    + " seq=0x" + mfgHexHex2(fr.get(:seq)) + " type=0x" + mfgHexHex2(fr.get(:cmdType)));
            }
            try {
                dispatchFrame(fr);
                if (VERBOSE_LOG) {
                    log("分发完成: cmd=" + fr.get(:cmdSet) + "/" + fr.get(:cmdId));
                }
            } catch (e) {
                log("帧处理异常: " + e.getErrorMessage());
            }
        }
    }

    function dispatchFrame(f as Dictionary) {
        var cs = f.get(:cmdSet);
        var cid = f.get(:cmdId);
        var ct = f.get(:cmdType);
        var isResp = (ct & 0x20) != 0;
        var payload = f.get(:payload);

        if (cs == 0x00 && cid == DJI_CMD_CONNECT) {
            handleConnectFrame(f, isResp, payload);
        }
        else if (cs == DJI_CMDSET_CAMERA && cid == DJI_CMD_STATUS_PUSH) {
            var st = djiParseStatusPush(payload);
            if (st != null) {
                mCameraStatus = st;
                mRecording = st.get(:recording);
                if (VERBOSE_LOG) {
                    log("状态推送: 电量 " + st.get(:battery) + "% 录制=" + mRecording);
                }
                mListener.onCameraStatus(st);
            }
        }
        else if (cs == DJI_CMDSET_CAMERA && cid == DJI_CMD_RECORD && isResp) {
            if (mPending != null && mPending.get(:kind) == :record
                    && mPending.get(:seq) == f.get(:seq)) {
                var starts = mPending.get(:startsRec);
                mPending = null;
                var ok = payload.size() > 0 && payload[0] == 0x00;
                if (ok) {
                    mRecording = starts; // 应答成功 → 真实录制状态
                }
                mListener.onRecordResult(ok, ok ? "OK" : "ret=" + payload[0]);
            }
        }
        else if (cs == 0x00 && cid == DJI_CMD_KEY_REPORT && isResp) {
            if (mPending != null && mPending.get(:kind) == :key
                    && mPending.get(:seq) == f.get(:seq)) {
                mPending = null;
                var ok2 = payload.size() > 0 && payload[0] == 0x00;
                if (ok2) {
                    mRecording = true; // 拍录键成功 = 已在拍摄
                }
                mListener.onRecordResult(ok2, ok2 ? "OK" : "ret=" + payload[0]);
            }
        }
        // 其余帧 (1D06 新状态推送、版本应答等) 忽略
    }

    // 0019 连接请求/应答的四种走向 (官方 connect_logic.c):
    //   应答帧 (isResp): 相机确认了我们的连接请求
    //   命令帧 (vm==2):  相机主动发来连接请求, verify_data 0=允许 / 1=拒绝
    function handleConnectFrame(f, isResp, payload) {
        if (isResp) {
            if (mPending != null && mPending.get(:kind) == :connect
                    && mPending.get(:seq) == f.get(:seq)) {
                mPending = null;
            }
            var rc = payload.size() > 4 ? payload[4] : -1;
            log("连接请求已确认 ret=" + rc + ", 等待相机确认");
            return;
        }
        var vm = payload.size() > 26 ? payload[26] : -1;
        var vd = payload.size() > 27 ? (payload[27] | (payload[28] << 8)) : -1;
        if (vm == 2 && vd == 0) {
            if (mPending != null && mPending.get(:kind) == :connect) {
                mPending = null;
            }
            log("相机允许连接 (相机请求 seq=0x" + mfgHexHex2(f.get(:seq)) + ")");
            // 判决实验: 保持通知开启, 相机握手后若推送, 观察是否仍崩溃
            var ack = djiBuildFrame(0x00, DJI_CMD_CONNECT, DJI_ACK_NO_RESPONSE,
                djiBuildConnectAckPayload(0x00, 0x00), f.get(:seq));
            log("已入队应答帧 (seq=0x" + mfgHexHex2(f.get(:seq)) + ")");
            // 注意: 必须用"带响应写"! FR255 实测无响应写(NORSP)在此特征上
            // 会触发蓝牙栈原生崩溃 (整个会话唯一的 NORSP 写 = 崩溃点)
            enqueueFrame(ack, DJI_WRITE_RSP);
            onProtocolReady();
        } else {
            log("相机拒绝连接 vm=" + vm + " vd=" + vd);
            mPending = null;
            setState(CAM_FAILED);
        }
    }

    function onProtocolReady() {
        log("进入就绪流程...");
        setState(CAM_READY);
        log("状态已置 READY");
        log("就绪流程完成");
        if (ENABLE_STATUS_SUB) {
            // 订阅相机状态推送 (2Hz, 含录制中/电量/剩余容量/电源模式)
            var seq = nextSeq();
            enqueueFrame(djiBuildFrame(DJI_CMDSET_CAMERA, DJI_CMD_STATUS_SUB,
                DJI_CMD_RESPONSE_OR_NOT, djiBuildStatusSubPayload(), seq), DJI_WRITE_RSP);
        }
    }

    // =========================================================================
    // 发送与重试
    // =========================================================================

    function nextSeq() as Number {
        mSeq = (mSeq + 1) & 0xFFFF;
        return mSeq;
    }

    function sendCommand(cmdSet, cmdId, payload, kind, name, startsRec as Boolean) as Boolean {
        log("sendCommand 进入: " + name + " state=" + mState);
        var seq = nextSeq();
        var frame = djiBuildFrame(cmdSet, cmdId, DJI_CMD_RESPONSE_OR_NOT, payload, seq);
        mPending = {
            :kind => kind, :seq => seq, :retries => CMD_MAX_RETRIES,
            :deadline => System.getTimer() + CMD_TIMEOUT_MS,
            :bytes => frame, :writeType => DJI_WRITE_RSP, :name => name,
            :startsRec => startsRec
        };
        enqueueFrame(frame, DJI_WRITE_RSP);
        return true;
    }

    // 入队并按 20B 分片; 发送由写完成回调驱动 (GATT 同时只允许一个写操作)
    function enqueueFrame(bytesArray, writeType) {
        log("入队: " + bytesArray.size() + "B");
        var n = bytesArray.size();
        if (n <= BLE_WRITE_MTU_LIMIT) {
            mSendQueue.add({ :bytes => bytesArray, :writeType => writeType });
        } else {
            var off = 0;
            while (off < n) {
                var end = (off + BLE_WRITE_MTU_LIMIT < n) ? off + BLE_WRITE_MTU_LIMIT : n;
                mSendQueue.add({ :bytes => bytesArray.slice(off, end), :writeType => writeType });
                off = end;
            }
        }
        ensureTimer();
        pumpQueue();
    }

    // 写队列泵: 空闲时发下一项 (特征写或描述符写)
    function pumpQueue() {
        if (mWriteBusy || mWriteChar == null || mSendQueue.size() == 0) {
            return;
        }
        var item = mSendQueue[0];
        mSendQueue = (mSendQueue.size() > 1) ? mSendQueue.slice(1, mSendQueue.size()) : [];
        mWriteBusy = true;
        mLastSendAt = System.getTimer();
        log("泵: 取出队列项");
        if (item.get(:desc) != null) {
            sendNowDesc(item.get(:desc), item.get(:bytes));
        } else {
            sendNow(item.get(:bytes), item.get(:writeType));
        }
    }

    // 描述符写入 (如关闭通知的 CCCD=0)
    function sendNowDesc(desc, valueBytes) {
        try {
            desc.requestWrite(valueBytes);
            log("DESC 写入已发");
        } catch (e) {
            log("DESC 写入异常: " + e.getErrorMessage());
            mWriteBusy = false;
            pumpQueue();
        }
    }

    // 描述符写入入队
    function enqueueDescriptorWrite(desc, valueBytes) {
        mSendQueue.add({ :desc => desc, :bytes => valueBytes });
        ensureTimer();
        pumpQueue();
    }

    // 特征写完成 (无论成败都继续队列)
    function onWriteDone(status as Number) {
        try {
            if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
                log("ATT 写失败 status=" + status);
            }
            mWriteBusy = false;
            pumpQueue();
        } catch (e) {
            log("写完成回调异常: " + e.getErrorMessage());
            mWriteBusy = false;
        }
    }

    // CCCD 描述符写完成
    function onDescriptorWriteDone(status as Number) {
        try {
            log("CCCD 写完成 status=" + status);
            mWriteBusy = false;
            pumpQueue();
        } catch (e) {
            log("描述符回调异常: " + e.getErrorMessage());
            mWriteBusy = false;
        }
    }

    function sendNow(bytesArray, writeType) {
        var n = bytesArray.size();
        // TX 诊断: 打印本片字节
        var digits = "0123456789ABCDEF";
        var hexs = "";
        for (var i = 0; i < n; i++) {
            var b = bytesArray[i];
            hexs = hexs + digits.substring((b >> 4) & 0x0F, ((b >> 4) & 0x0F) + 1)
                + digits.substring(b & 0x0F, (b & 0x0F) + 1);
        }
        log("TX[" + n + "]: " + hexs);
        try {
            // 动态 ByteArray 的官方途径: b 字面量零模板 + encodeNumber + slice
            var tmpl = [0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00]b;
            for (var i = 0; i < n; i++) {
                tmpl.encodeNumber(bytesArray[i], Lang.NUMBER_FORMAT_UINT8, { :offset => i });
            }
            var ba = tmpl.slice(0, n);
            log("写入调用前 (ByteArray " + ba.size() + "B)");
            mWriteChar.requestWrite(ba, { :writeType => writeType });
            log("写入调用返回");
        } catch (e) {
            log("写入异常: " + e.getErrorMessage());
            mWriteBusy = false;
            pumpQueue();
        }
    }

    function ensureTimer() {
        if (!mUseTimer) {
            return; // 数据字段: 心跳由 compute() 驱动
        }
        if (!mTimerOn) {
            // SDK 9.3.0: start(callback, time, repeat) 只有 3 个参数, 回调必须无参
            mTimer.start(method(:onTick), 100, true);
            mTimerOn = true;
        }
    }

    function stopTimer() {
        if (mTimerOn) {
            mTimerOn = false;
            if (mTimer != null) {
                mTimer.stop();
            }
        }
    }

    // watch-app 内部 Timer 心跳 (100ms)
    function onTick() {
        tickGuarded();
    }

    // datafield 心跳入口 (compute 1Hz, 无 Timer 权限)
    function onCompute() {
        tickGuarded();
    }

    function tickGuarded() {
        try {
            onTickInner();
        } catch (e) {
            log("心跳异常: " + e.getErrorMessage());
            mSendQueue = [];
            mPending = null;
            stopTimer();
        }
    }

    var mTickMarked;

    function onTickInner() {
        if (!mTickMarked) {
            mTickMarked = true;
            log("定时器已运行");
        }
        var now = System.getTimer();
        // CONNECTING 超时兜底: 配对后相机始终未完成连接
        if (mState == CAM_CONNECTING && mConnectingDeadline > 0 && now > mConnectingDeadline) {
            mConnectingDeadline = 0;
            log("连接超时");
            setState(CAM_FAILED);
            stopTimer();
            return;
        }
        // 写操作卡死保护 (完成回调丢失时兜底)
        if (mWriteBusy && (now - mLastSendAt) > 3000) {
            mWriteBusy = false;
            log("写操作卡死超时, 重置");
            pumpQueue();
        }
        if (mSendQueue.size() > 0) {
            pumpQueue();
        }
        if (mPending != null && now > mPending.get(:deadline)) {
            var p = mPending;
            if (p.get(:retries) > 0) {
                p.put(:retries, p.get(:retries) - 1);
                p.put(:deadline, now + CMD_TIMEOUT_MS);
                log("无响应, 重发 " + p.get(:name));
                enqueueFrame(p.get(:bytes), p.get(:writeType));
            } else {
                var kind = p.get(:kind);
                var name = p.get(:name);
                mPending = null;
                mSendQueue = [];
                mWriteBusy = false;
                log("命令失败(超时): " + name);
                if (kind == :connect) {
                    setState(CAM_FAILED);
                } else {
                    mListener.onRecordResult(false, "timeout");
                }
            }
        }
        if (mSendQueue.size() == 0 && mPending == null) {
            stopTimer();
        }
    }

    // =========================================================================
    // 辅助
    // =========================================================================

    function isCameraAsleep() as Boolean {
        return (mCameraStatus != null && mCameraStatus.get(:powerMode) == DJI_CAM_POWER_SLEEP);
    }

    function armConnectingTimeout() {
        mConnectingDeadline = System.getTimer() + 20000;
        ensureTimer();
    }

    function setState(s as Number) {
        if (mState != s) {
            mState = s;
            try {
                mListener.onCameraState(s);
            } catch (e) {
                System.println("DJI: onCameraState 异常 " + e.getErrorMessage());
            }
        }
    }

    function log(msg as String) {
        System.println("DJI: " + msg);
        mLog.add(System.getTimer() + " " + msg);
        if (mLog.size() > 6) {
            mLog = mLog.slice(mLog.size() - 6, mLog.size());
        }
    }

    function getLog() as Array<String> {
        return mLog;
    }
}
