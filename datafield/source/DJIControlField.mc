// ============================================================================
// DJIControlField.mc — DJI Action 4 拍录联动数据字段
//
// 用法: 把本字段添加到运动模式的数据页。字段自动连接相机。
//   运动计时开始  → 相机开始录像
//   计时结束/保存 → 相机停止录像
//   计时暂停/恢复 → 相机不受影响, 继续录制
// 运动中把本字段页保持在屏幕上即可; 不用时相机可正常手动操作。
// ============================================================================

import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.System;
import Toybox.Attention;
import Toybox.Activity;
import Toybox.Lang;

class DJIControlField extends WatchUi.DataField {

    var mClient;
    var mStatus;       // 最近一次 1D02 相机状态
    var mStateText;
    var mRecordMsg;    // 最近一次命令结果提示
    var mPendingVibe;  // 延后振动: 1=成功/连接, -1=失败

    function initialize(client) {
        WatchUi.DataField.initialize();
        mStateText = "INIT";
        mRecordMsg = "";
        mPendingVibe = 0;
        mClient = client; // CameraClient 由 DJIControlApp (AppBase 壳) 创建并传入
    }

    // ---- CameraClient 监听回调 ----

    // ★ BLE 回调链内禁止 vibe/WatchUi 调用 (FR255 原生崩溃, 与 TestApp 同根因)
    // 只更新变量; 数据字段由系统每秒自动重绘, 振动延后到 onUpdate (UI 上下文) 触发
    function onCameraState(state as Number) {
        mStateText = stateText(state);
        if (state == CAM_READY) {
            mPendingVibe = 1;
        } else if (state == CAM_FAILED) {
            mPendingVibe = -1;
        }
    }

    function onCameraStatus(status as Dictionary) {
        mStatus = status;
    }

    function onRecordResult(success as Boolean, msg as String) {
        mRecordMsg = success ? "OK" : ("ERR " + msg);
        mPendingVibe = success ? 1 : -1;
    }

    function vibe(ok as Boolean) {
        try {
            if (ok) {
                Attention.vibrate([new Attention.VibeProfile(70, 90)]);
            } else {
                Attention.vibrate([new Attention.VibeProfile(100, 250),
                    new Attention.VibeProfile(100, 250)]);
            }
        } catch (e) {
            // 个别设备/场景不支持振动, 忽略
        }
    }

    function stateText(state as Number) as String {
        switch (state) {
        case CAM_IDLE:
            return "OFF";
        case CAM_SCANNING:
            return "SCAN";
        case CAM_CONNECTING:
            return "CONN";
        case CAM_BLE_READY:
            return "SETUP";
        case CAM_READY:
            return "LINK";
        case CAM_FAILED:
            return "FAIL";
        }
        return "?";
    }

    // 系统每秒调用 (字段可见时): 驱动客户端心跳 (重发/超时/队列兜底)
    function compute(info as Activity.Info) as Void {
        mClient.onCompute();
    }

    // ---- 数据字段生命周期 → 相机命令 ----
    // 计时开始/结束联动录像; 暂停/恢复不动作 (用户要求: 暂停不停止录像)

    function onTimerStart() as Void {
        mClient.startRecording();
    }

    function onTimerStop() as Void {
        mClient.stopRecording();
    }

    // ---- 绘制 ----

    function onUpdate(dc as Graphics.Dc) as Void {
        // 振动延后到 UI 绘制上下文触发 (回调链内调用会原生崩溃)
        try {
            if (mPendingVibe != 0) {
                var v = mPendingVibe;
                mPendingVibe = 0;
                vibe(v == 1);
            }
        } catch (e) {
            System.println("DJI: 振动异常 " + e.getErrorMessage());
        }
        dc.clear();
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        var recording = mClient.isRecording();
        var linked = (mClient.getState() == CAM_READY);

        // 顶部: 连接状态
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_BLACK);
        dc.drawText(cx, 0, Graphics.FONT_XTINY, "DJI " + mStateText,
            Graphics.TEXT_JUSTIFY_CENTER);

        // 中部: 录制状态
        var midY = h / 2 - 16;
        if (recording) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_BLACK);
            dc.fillRectangle(cx - 44, midY + 4, 10, 10);
            dc.drawText(cx - 22, midY, Graphics.FONT_SMALL, "REC",
                Graphics.TEXT_JUSTIFY_LEFT);
            // 录制时长 (来自相机状态推送)
            var t = -1;
            if (mStatus != null && mStatus.get(:recordTimeSec) != null) {
                t = mStatus.get(:recordTimeSec);
            }
            if (t >= 0) {
                dc.drawText(cx + 20, midY, Graphics.FONT_XTINY, fmtTime(t),
                    Graphics.TEXT_JUSTIFY_LEFT);
            }
        } else {
            dc.setColor(linked ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY, Graphics.COLOR_BLACK);
            dc.drawText(cx, midY, Graphics.FONT_SMALL, "STBY",
                Graphics.TEXT_JUSTIFY_CENTER);
        }

        // 底部: 相机电量 / SD 卡剩余 / 命令结果
        var line = "";
        if (mStatus != null) {
            var bat = mStatus.get(:battery);
            var sd = mStatus.get(:remainCapacityMb);
            if (bat != null) {
                line = "BAT " + bat + "%";
            }
            if (sd != null && sd > 0) {
                line = line + "  SD " + (sd / 1024) + "G";
            }
        }
        if (mRecordMsg.length() > 0) {
            line = mRecordMsg;
        }
        if (line.length() > 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_BLACK);
            dc.drawText(cx, h - 16, Graphics.FONT_XTINY, line,
                Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    function fmtTime(sec as Number) as String {
        var m = sec / 60;
        var s = sec % 60;
        return m + ":" + (s < 10 ? "0" + s : "" + s);
    }
}
