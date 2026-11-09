// ============================================================================
// DjiProtocol.mc — DJI "R SDK" 蓝牙协议实现（Osmo Action 4 / 5 Pro / 6, Osmo 360）
//
// 帧格式与命令定义来自 DJI 官方开源工程:
//   github.com/dji-sdk/Osmo-GPS-Controller-Demo
//   (docs/protocol_CN.md, docs/protocol_data_segment_CN.md, ble/ble.c)
//
// CRC 参数已用官方测试向量验证通过:
//   connect_cmd_frame.txt 全部 10 帧 + 文档中的统一模式切换示例帧
//   CRC16: init 0x3AA3, poly 0xA001 (反射), 无终值异或, 覆盖 SOF..SEQ
//   CRC32: init 0x3AA3, poly 0xEDB88320 (反射), 无终值异或, 覆盖 SOF..DATA
// ============================================================================

import Toybox.Lang;
// 帧布局 (小端):
//   [0]  SOF = 0xAA
//   [1..2]  Ver/Length: 高 6 位版本(固定 0), 低 10 位 = 整帧总长
//   [3]  CmdType: bit5=帧类型(0命令/1应答), bit4..0=应答类型(0无/1可选/2必须)
//   [4]  ENC = 0 (不加密)
//   [5..7] RES = 0
//   [8..9]  SEQ (小端)
//   [10..11] CRC16 (覆盖 [0..9])
//   [12] CmdSet  [13] CmdID
//   [14..] payload
//   [末4] CRC32 (覆盖 [0..末5])
// ============================================================================

// ---- (CmdSet, CmdID) 定义 ----
const DJI_CMDSET_SYSTEM   = 0x00; // 系统类
const DJI_CMDSET_CAMERA   = 0x1D; // 相机类

const DJI_CMD_CONNECT     = 0x19; // 0019 连接请求/应答
const DJI_CMD_KEY_REPORT  = 0x11; // 0011 按键上报 (拍录键 0x01)
const DJI_CMD_GPS_PUSH    = 0x17; // 0017 GPS 推送 (预留扩展)
const DJI_CMD_POWER_MODE  = 0x1A; // 001A 相机电源模式 (0 正常 / 3 休眠)

const DJI_CMD_STATUS_PUSH = 0x02; // 1D02 相机状态推送
const DJI_CMD_RECORD      = 0x03; // 1D03 拍录控制
const DJI_CMD_STATUS_SUB  = 0x05; // 1D05 相机状态订阅

// ---- CmdType 应答类型 ----
const DJI_CMD_NO_RESPONSE     = 0x00; // 发送后不需要应答
const DJI_CMD_RESPONSE_OR_NOT = 0x01; // 需要应答, 不应答也没关系
const DJI_CMD_WAIT_RESULT     = 0x02; // 必须应答
const DJI_ACK_NO_RESPONSE     = 0x20; // 应答帧 (bit5=1), 无需再应答

// ---- device_id (protocol_data_segment_CN.md) ----
const DJI_DEVICE_ID_WATCH   = 0x12345678; // 手表端 device_id (官方测试帧取值)
const DJI_DEVICE_ID_RECORD  = 0x33FF0000; // 拍录控制命令帧 device_id (照抄官方 demo 实现)
const DJI_DEVICE_ID_ACTION4 = 0xFF33;     // Osmo Action 4 的相机 device_id

// ---- 相机状态推送 (1D02) 字段含义 ----
const DJI_CAM_STATUS_RECORDING = 0x03; // 拍照或录像中
const DJI_CAM_POWER_SLEEP      = 0x03; // 休眠模式

// CRC16: 反射逐位实现, 等价于官方查表法
function djiCrc16(data as Array<Number>) as Number {
    var crc = 0x3AA3;
    var n = data.size();
    for (var i = 0; i < n; i++) {
        crc ^= (data[i] & 0xFF);
        for (var j = 0; j < 8; j++) {
            crc = ((crc & 0x01) != 0) ? ((crc >> 1) ^ 0xA001) : (crc >> 1);
        }
    }
    return crc & 0xFFFF;
}

// CRC32: 标准反射逐位实现
// Monkey C Number 为 32 位有符号数, 右移后需掩掉符号扩展位
function djiCrc32(data as Array<Number>) as Number {
    var crc = 0x3AA3;
    var n = data.size();
    for (var i = 0; i < n; i++) {
        crc ^= (data[i] & 0xFF);
        for (var j = 0; j < 8; j++) {
            crc = ((crc & 0x01) != 0)
                ? (((crc >> 1) & 0x7FFFFFFF) ^ 0xEDB88320)
                : ((crc >> 1) & 0x7FFFFFFF);
        }
    }
    return crc;
}

function djiU16le(v as Number) as Array<Number> {
    return [v & 0xFF, (v >> 8) & 0xFF];
}

function djiU32le(v as Number) as Array<Number> {
    return [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
}

// 构造完整协议帧, 返回字节数组
function djiBuildFrame(cmdSet as Number, cmdId as Number, cmdType as Number,
                       payload as Array<Number> or Null, seq as Number) as Array<Number> {
    var dataLen = (payload == null) ? 0 : payload.size();
    var total = 14 + dataLen + 4;
    var f = [];
    f.add(0xAA);
    var verLen = total & 0x03FF;
    f.add(verLen & 0xFF);
    f.add((verLen >> 8) & 0xFF);
    f.add(cmdType & 0x3F);
    f.add(0x00); // ENC: 不加密
    f.add(0x00); // RES
    f.add(0x00);
    f.add(0x00);
    f.add(seq & 0xFF);
    f.add((seq >> 8) & 0xFF);
    var c16 = djiCrc16(f);
    f.add(c16 & 0xFF);
    f.add((c16 >> 8) & 0xFF);
    f.add(cmdSet & 0xFF);
    f.add(cmdId & 0xFF);
    if (payload != null) {
        var pn = payload.size();
        for (var i = 0; i < pn; i++) {
            f.add(payload[i] & 0xFF);
        }
    }
    var c32 = djiCrc32(f);
    f.add(c32 & 0xFF);
    f.add((c32 >> 8) & 0xFF);
    f.add((c32 >> 16) & 0xFF);
    f.add((c32 >> 24) & 0xFF);
    return f;
}

// --------------------------------------------------------------------------
// payload 构造
// --------------------------------------------------------------------------

// 0019 连接请求 payload (33 字节)
// verifyMode: 1 = 首次配对(相机弹窗, 用户确认), 0 = 已配对(相机按配对历史决定是否弹窗)
// MAC 使用固定占位值: 相机按此地址记忆配对历史, 首次确认后重连不再弹窗
function djiBuildConnectPayload(verifyMode as Number, verifyData as Number) as Array<Number> {
    var p = djiU32le(DJI_DEVICE_ID_WATCH);
    p.add(0x06); // mac_addr_len = 6
    var mac = [0x38, 0x34, 0x56, 0x78, 0x9A, 0xBC]; // 官方测试帧占位 MAC
    for (var i = 0; i < 16; i++) {
        p.add(i < mac.size() ? mac[i] : 0x00);
    }
    var fw = djiU32le(0);
    for (var k = 0; k < 4; k++) { p.add(fw[k]); } // fw_version = 0: 不触发固件升级提示
    p.add(0x00); // conidx
    p.add(verifyMode & 0xFF);
    var vd = djiU16le(verifyData);
    for (var m = 0; m < 2; m++) { p.add(vd[m]); }
    for (var j = 0; j < 4; j++) { p.add(0x00); } // reserved
    return p;
}

// 0019 连接应答 payload (9 字节), reserved[0] = 相机编号 (单机 = 0)
function djiBuildConnectAckPayload(retCode as Number, cameraIndex as Number) as Array<Number> {
    var p = djiU32le(DJI_DEVICE_ID_WATCH);
    p.add(retCode & 0xFF);
    p.add(cameraIndex & 0xFF);
    p.add(0x00);
    p.add(0x00);
    p.add(0x00);
    return p;
}

// 1D03 拍录控制 payload (9 字节): record_ctrl 0 = 开始, 1 = 停止
function djiBuildRecordPayload(startRecord as Boolean) as Array<Number> {
    var p = djiU32le(DJI_DEVICE_ID_RECORD);
    p.add(startRecord ? 0x00 : 0x01);
    for (var i = 0; i < 4; i++) { p.add(0x00); }
    return p;
}

// 0011 按键上报 payload (4 字节)
// 拍录键(0x01)短按: 相机休眠时会唤醒并立即开始拍摄; 录制中则为停止
// mode 0x01 = 按键事件, key_value 0x0000 = 短按
function djiBuildKeyPayload(keyCode as Number, keyValue as Number) as Array<Number> {
    var p = [keyCode & 0xFF, 0x01];
    var kv = djiU16le(keyValue);
    for (var i = 0; i < 2; i++) { p.add(kv[i]); }
    return p;
}

// 1D05 相机状态订阅 payload (6 字节)
// push_mode 3 = 周期 + 状态变化后推送一次; push_freq 只能填 20 (固定 2Hz)
function djiBuildStatusSubPayload() as Array<Number> {
    var p = [0x03, 0x14];
    for (var i = 0; i < 4; i++) { p.add(0x00); }
    return p;
}

// 001A 相机电源模式 payload: 0 = 正常, 3 = 休眠
function djiBuildPowerPayload(mode as Number) as Array<Number> {
    return [mode & 0xFF];
}

// --------------------------------------------------------------------------
// payload 解析
// --------------------------------------------------------------------------

// 解析 1D02 相机状态推送 payload (38 字节), 字段偏移见官方 protocol_data_segment_CN.md
function djiParseStatusPush(p as Array<Number>) as Dictionary or Null {
    if (p.size() < 38) {
        return null;
    }
    return {
        :cameraMode    => p[0],                                // 0x01 = 视频模式
        :cameraStatus  => p[1],                                // 0x03 = 拍照/录像中
        :recording     => (p[1] == DJI_CAM_STATUS_RECORDING),
        :resolution    => p[2],
        :fpsIdx        => p[3],
        :recordTimeSec => p[5] | (p[6] << 8),
        :remainCapacityMb => p[15] | (p[16] << 8) | (p[17] << 16) | (p[18] << 24),
        :remainTimeSec => p[23] | (p[24] << 8) | (p[25] << 16) | (p[26] << 24),
        :powerMode     => p[28],                               // 3 = 休眠
        :tempOver      => p[30],
        :battery       => p[37]
    };
}

// --------------------------------------------------------------------------
// 流式帧解析
// --------------------------------------------------------------------------
class DjiFrameParser {

    var mBuf;

    function initialize() {
        mBuf = [];
    }

    // 喂入一包 fff4 通知数据, 返回解析出的帧数组
    // 每帧: {:cmdSet, :cmdId, :cmdType, :seq, :payload}
    // 通知可能分片/粘连, 且 Osmo Action 5 会混发 0x55 帧 — 按 SOF 扫描 + 双 CRC 校验做重同步
    function addBytes(bytes) as Array<Dictionary> {
        var arr;
        if (bytes instanceof Lang.ByteArray) {
            // ByteArray 无下标访问, 用 decodeNumber 逐字节读出
            var ba = bytes;
            var bn = ba.size();
            arr = [];
            for (var i = 0; i < bn; i++) {
                arr.add(ba.decodeNumber(Lang.NUMBER_FORMAT_UINT8, { :offset => i }));
            }
        } else {
            arr = bytes;
        }
        var bn = arr.size();
        for (var i = 0; i < bn; i++) {
            mBuf.add(arr[i] & 0xFF);
        }
        var frames = [];
        var progressing = true;
        while (progressing) {
            progressing = false;
            var n = mBuf.size();
            // 重同步: 丢弃 SOF 前的字节
            var start = -1;
            for (var i = 0; i < n; i++) {
                if (mBuf[i] == 0xAA) {
                    start = i;
                    break;
                }
            }
            if (start < 0) {
                mBuf = [];
                break;
            }
            if (start > 0) {
                mBuf = mBuf.slice(start, n);
                n = mBuf.size();
                progressing = true;
                continue;
            }
            if (n < 16) {
                break; // 帧头未收全 (最短帧 18 字节)
            }
            var total = mBuf[1] | ((mBuf[2] & 0x03) << 8);
            if (total < 16 || total > 512) {
                mBuf = mBuf.slice(1, n); // 假 SOF
                progressing = true;
                continue;
            }
            if (n < total) {
                break; // 帧未收全
            }
            var exp16 = mBuf[10] | (mBuf[11] << 8);
            if (djiCrc16(mBuf.slice(0, 10)) != exp16) {
                mBuf = mBuf.slice(1, n);
                progressing = true;
                continue;
            }
            var exp32 = mBuf[total - 4] | (mBuf[total - 3] << 8)
                      | (mBuf[total - 2] << 16) | (mBuf[total - 1] << 24);
            if (djiCrc32(mBuf.slice(0, total - 4)) != exp32) {
                mBuf = mBuf.slice(1, n);
                progressing = true;
                continue;
            }
            frames.add({
                :cmdSet   => mBuf[12],
                :cmdId    => mBuf[13],
                :cmdType  => mBuf[3],
                :seq      => mBuf[8] | (mBuf[9] << 8),
                :payload  => mBuf.slice(14, total - 4)
            });
            mBuf = mBuf.slice(total, n);
            progressing = true;
        }
        return frames;
    }
}
