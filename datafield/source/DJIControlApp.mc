// ============================================================================
// DJIControlApp.mc — 数据字段应用壳 (系统入口)
// 结构约定 (Garmin FieldTimerEvents 示例): type="datafield" 的入口类必须
// 继承 Application.AppBase, 通过 getInitialView() 返回数据字段视图;
// 计时器事件 (onTimerStart 等) 在视图类上。
// ============================================================================
import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class DJIControlApp extends Application.AppBase {

    var mClient;
    var mField;

    function initialize() {
        Application.AppBase.initialize();
        // App 壳作为 CameraClient 的监听者, 转发给视图 (视图在 getInitialView 时创建)
        mClient = new CameraClient(self, false); // 数据字段无 Timer 权限, 由 compute() 驱动
    }

    function onStart(state as Dictionary?) as Void {
        mClient.start();
    }

    function onStop(state as Dictionary?) as Void {
        mClient.close();
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        mField = new DJIControlField(mClient);
        return [mField];
    }

    // ---- CameraClient 监听转发 (BLE 回调链内零 UI 调用) ----

    function onCameraState(state as Number) {
        if (mField != null) {
            mField.onCameraState(state);
        }
    }

    function onCameraStatus(status as Dictionary) {
        if (mField != null) {
            mField.onCameraStatus(status);
        }
    }

    function onRecordResult(success as Boolean, msg as String) {
        if (mField != null) {
            mField.onRecordResult(success, msg);
        }
    }
}
