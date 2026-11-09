// ============================================================================
// TestApp.mc — DJI 相机控制测试 App
//
// 用于不进运动模式时验证 BLE 链路与协议:
//   启动 App 即自动扫描/连接相机
//   ENTER  : 开始/停止录像 (按当前状态切换)
//   UP     : 手动重连 (重新扫描)
//   DOWN   : 停止录像
//   BACK   : 退出
// 屏幕显示连接状态、相机状态推送、命令日志 (最近 6 条)。
// ============================================================================

import Toybox.Application;
import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.System;
import Toybox.Attention;
import Toybox.Lang;

class TestApp extends Application.AppBase {

    var mClient;

    function initialize() {
        Application.AppBase.initialize();
        mClient = new CameraClient(self, true); // watch-app 可用 Timer (100ms 心跳)
    }

    // 自动测试已移至 CameraClient.onTick (BLE 回调外的安全上下文)

    function onStart(state as Dictionary or Null) as Void {
        mClient.start();
    }

    function onStop(state as Dictionary or Null) as Void {
        mClient.close();
    }

    function getInitialView() {
        return [new TestView(mClient), new TestDelegate(mClient)];
    }

    // ---- CameraClient 监听回调 ----

    function onCameraState(state as Number) {
        // ★ 根因修复: BLE 回调链内禁止调用 vibe/Timer/WatchUi (FR255 原生崩溃)
        // 只记录状态, UI 由系统自然刷新, 振动由客户端心跳触发
        System.println("DJI: onCameraState(仅记录) state=" + state);
    }

    function onCameraStatus(status as Dictionary) {
        System.println("DJI: onCameraStatus(仅记录)");
    }

    function onRecordResult(success as Boolean, msg as String) {
        System.println("DJI: onRecordResult(仅记录) " + success + " " + msg);
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
        }
    }
}

class TestView extends WatchUi.View {

    var mClient;

    function initialize(client) {
        WatchUi.View.initialize();
        mClient = client;
    }

    function onLayout(dc as Graphics.Dc) as Void {
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        try {
            onUpdateInner(dc);
        } catch (e) {
            System.println("DJI: UI 绘制异常 " + e.getErrorMessage());
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_BLACK);
            dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2, Graphics.FONT_TINY,
                "UI ERR", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    function onUpdateInner(dc as Graphics.Dc) as Void {
        dc.clear();
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        var state = mClient.getState();
        var recording = mClient.isRecording();

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_BLACK);
        dc.drawText(cx, 2, Graphics.FONT_TINY, "DJI Test - " + stateText(state),
            Graphics.TEXT_JUSTIFY_CENTER);

        var y = h / 4;
        dc.setColor(recording ? Graphics.COLOR_RED : Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.drawText(cx, y, Graphics.FONT_MEDIUM, recording ? "REC" : "STBY",
            Graphics.TEXT_JUSTIFY_CENTER);

        // 相机状态推送摘要
        var st = mClient.getCameraStatus();
        var line2 = "no status yet";
        if (st != null) {
            line2 = "bat " + st.get(:battery) + "%  mode " + st.get(:cameraMode)
                + "  rec " + st.get(:recordTimeSec) + "s";
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.drawText(cx, h / 2, Graphics.FONT_TINY, line2, Graphics.TEXT_JUSTIFY_CENTER);

        // 操作说明 + 日志
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_BLACK);
        dc.drawText(cx, h / 2 + 22, Graphics.FONT_TINY,
            "ENTER=start/stop UP=reconnect", Graphics.TEXT_JUSTIFY_CENTER);
        var logs = mClient.getLog();
        var ly = h - 18 - logs.size() * 16;
        var ln2 = logs.size();
        for (var i = 0; i < ln2; i++) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_BLACK);
            dc.drawText(4, ly, Graphics.FONT_TINY, logs[i], Graphics.TEXT_JUSTIFY_LEFT);
            ly = ly + 16;
        }
    }

    function stateText(state as Number) as String {
        switch (state) {
        case CAM_IDLE:        return "OFF";
        case CAM_SCANNING:    return "SCAN";
        case CAM_CONNECTING:  return "CONN";
        case CAM_BLE_READY:   return "SETUP";
        case CAM_READY:       return "LINK";
        case CAM_FAILED:      return "FAIL";
        }
        return "?";
    }
}

class TestDelegate extends WatchUi.BehaviorDelegate {

    var mClient;

    function initialize(client) {
        WatchUi.BehaviorDelegate.initialize();
        mClient = client;
    }

    // ENTER: 按当前状态切换开始/停止
    function onSelect() as Boolean {
        if (mClient.isRecording()) {
            mClient.stopRecording();
        } else {
            mClient.startRecording();
        }
        WatchUi.requestUpdate();
        return true;
    }

    // UP: 重新扫描/连接
    function onNextPage() as Boolean {
        mClient.reconnect();
        WatchUi.requestUpdate();
        return true;
    }

    // DOWN: 停止录像
    function onPreviousPage() as Boolean {
        mClient.stopRecording();
        WatchUi.requestUpdate();
        return true;
    }
}
