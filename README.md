# garmin-connect-dji

**Garmin 手表遥控 DJI Action 运动相机** — 在 Garmin 手表上通过 BLE 直连 DJI Osmo Action 系列相机，实现运动开始自动开录、结束自动停录，全程只操作手表。

> A Connect IQ data field that lets Garmin watches start/stop recording on DJI Osmo Action cameras over Bluetooth LE. Verified end-to-end on Forerunner 255 + Osmo Action 4.

[详细设计文档（中文）](实现方案.md)

---

## 功能

- **自动联动**：进入运动（骑行/跑步等）后自动连接相机；计时开始→相机开录；计时结束→停录
- **暂停不停止**：运动中途暂停（等红灯）不会打断录像，不产生碎片文件
- **实时状态**：字段上显示连接状态、REC 红点、录制时长、相机电量、SD 卡剩余
- **命令确认**：每条录像命令等待相机应答，失败自动重发，振动提示结果
- **自动重连**：连接断开自动重扫重连；相机休眠时自动发"拍录键"唤醒并开录

## 工作原理

```
┌─────────────────────────── Garmin 手表 ───────────────────────────┐
│  原生运动模式 (骑行/跑步…)                                          │
│   └─ 数据字段 [DJI Cam Control]                                    │
│        ├─ AppBase 壳: 管理连接生命周期 (onStart/onStop)             │
│        ├─ 视图: 计时事件驱动录像命令 + 每秒绘制状态                  │
│        └─ 心跳: 数据字段由 compute() 驱动, 应用由 Timer 驱动        │
│                    │ BLE central (GATT client)                     │
└────────────────────┼───────────────────────────────────────────────┘
                     │ 写 FFF5 (命令) / 收 FFF4 (应答与状态)
┌────────────────────▼───────────── DJI Osmo Action 4 ──────────────┐
│  GATT 服务 FFF0                                                    │
│  DJI R SDK 协议 (0xAA 帧): 0019 握手 → 1D03 拍录控制 → 1D02 状态推送 │
└────────────────────────────────────────────────────────────────────┘
```

协议为 **DJI 官方 R SDK 蓝牙协议**（与 DJI 官方开源的
[Osmo-GPS-Controller-Demo](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo)
遥控器同源），帧格式、CRC 参数与官方测试向量逐字节核对。

## 支持设备

- **手表（已验证）**：Forerunner 255 标准版（固件 29.05 / CIQ 6.0.4）
- **手表（理论兼容）**：2022 年后发布、支持 CIQ BLE central 的机型——Fenix 7/8、Epix 2、
  Enduro 3、FR165/265/570/955/965/970、Venu 3/4、vivoactive 5、Instinct 3、MARQ 2、
  Descent Mk3（manifest 已含 39 个机型，构建时逐一校验过）
- **相机**：Osmo Action 4（0xFF33）；协议同源支持 Action 5 Pro (0xFF44) / Action 6 (0xFF55) /
  Osmo 360 (0xFF66)

判断你的手表是否支持：在 Connect IQ Store 打开官方
[GoPro Camera Control](https://apps.garmin.com/en-US/apps/b6474aef-4b36-46ea-b7e5-6e8612b50e9d)
查看"兼容设备"列表。

## 安装使用

1. 从 [Releases](../../releases) 下载 `DJIFIELD.PRG`，复制到手表 U 盘 `GARMIN\APPS\`
   （**文件名保持 8.3 格式**，拔线前安全弹出）；
2. 长按 UP → 活动和应用 → 骑行 → 活动设置 → 数据页 → 添加字段 **DJI Cam Control**；
3. 相机开机（无线连接开启、亮屏、手机 Mimo 未连接）；
4. 启动骑行计时 → 相机自动开录；结束保存 → 自动停录；**暂停计时不会打断录像**。

字段页显示期间：REC 红点与录制时长实时显示；连接失败或命令异常有振动提示。

## 从源码构建

依赖：[Connect IQ SDK 9.3.0+](https://developer.garmin.com/connect-iq/sdk/)（含设备包）、
JDK 11+、OpenSSL。仓库自带 `jdk/`（Windows 可选，脚本自动使用）。

```bat
:: Windows
build.bat              :: 默认 fr255, 产物在 bin\ 下
build.bat fenix7       :: 指定其他机型
```

```bash
# Linux / macOS / Git Bash
./build.sh
```

原始命令：

```bash
sdk/bin/monkeyc -f datafield/monkey.jungle -d fr255 -y developer_key.der -w -o bin/DJIFIELD.PRG
```

**开发者密钥必须是 RSA 4096 位**（生成与 DER 转换见下文踩坑清单）。
编译产物通过 GitHub Releases 分发；`bin/` 已在 .gitignore 中。

### 模拟器

```bash
sdk/bin/connectiq.bat                                  :: 启动模拟器
sdk/bin/monkeydo bin/DJITEST.PRG fr255                 :: 加载测试 App
```

模拟器渲染文字需先在 SDK Manager 的 **Devices** 标签下载对应设备包（补齐字体文件）。

## FR255 踩坑清单（血泪经验，做 Garmin BLE 应用必读）

本项目联调过程中定位了 **4 个 FR255 专属的坑**，每一个都会导致"静默失败"（不报错、不工作）：

| # | 坑 | 症状 | 规避 |
|---|-----|------|------|
| 1 | **PRG 文件名必须 8.3 格式**（主名 ≤8 字符） | 拷进 `GARMIN/APPS/` 的长文件名 PRG 重连后被**静默删除**，不装不报错 | 输出 `DJITEST.PRG` 这类短名 |
| 2 | **开发者密钥必须 RSA 4096 位** | 2025 Q2 起固件对侧载应用做新签名校验，2048 位密钥签名=签名校验失败、静默拒收 | `openssl genrsa -out key.pem 4096` |
| 3 | **`Timer.start()` 只有 3 个参数**且回调**无参** | 4 参调用抛 `Too Many Arguments Error`；若标志位先置位，定时器静默失效+未保护路径崩溃 | `start(method, ms, true)`；`onTick()` 不带参 |
| 4 | **数据字段入口必须是 AppBase 壳** | 把 DataField 类直接当 entry → `Failed to start CIQ Application / Unexpected Type Error`（空堆栈） | AppBase 壳 + `getInitialView()` 返回字段视图；`compute()` 代替 Timer 驱动心跳 |

**崩溃日志是联调第一手证据**：手表 USB 的 `CIQ_LOG.YML`（YAML 格式，含符号化堆栈），
用 `tools/symbolicate.py` 翻译 pc 地址。本项目的崩溃就是靠它最终定位的（前三轮盲试走了弯路）。

另外两个设备库层面的差异：数据字段**无 `Toybox.Timer` 权限**（改用 `compute()` 驱动心跳）；
模拟器的 fr255 字体资源依赖设备包（社区提取的设备包缺字体，模拟器渲染会崩，真机不受影响）。

## 已知限制

- 需要相机在配对时于相机屏幕上确认一次（官方握手协议要求）；之后自动静默重连
- 相机休眠超过 30 分钟后无法 BLE 唤醒（官方限制），建议运动前手动开机并关闭自动关机
- 未实现 GPS 推送（0017）：录像文件不含 GPS 仪表盘数据（协议已具备，欢迎 PR）
- 多台相机同场时连接扫描到的第一台

## 仓库结构

```
datafield/   正式数据字段工程 (App 壳 + 视图)
testapp/     调试 App 工程 (手动控制, 验证链路用)
shared/      协议编解码 (DjiProtocol) + 相机客户端 (CameraClient)
tools/       图标生成 / 崩溃日志符号化 / CRC 测试脚本与官方测试向量
build.bat    Windows 一键编译
build.sh     Linux/macOS/Git Bash 一键编译
实现方案.md   详细设计文档 (中文)
```

## 致谢与参考

- [DJI Osmo-GPS-Controller-Demo](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo) —
  DJI 官方开源遥控器 Demo，本项目的协议权威来源（MIT）
- [datagutt/node-osmo](https://github.com/datagutt/node-osmo) —
  Osmo 系列 BLE 控制库，交叉验证
- [yigitkonur/lib-osmo-ble](https://github.com/yigitkonur/lib-osmo-ble) —
  DUML-over-BLE 协议文档
- Garmin
  [FieldTimerEvents](https://developer.garmin.com/connect-iq/sample-code/) /
  [NordicThingy52](https://developer.garmin.com/connect-iq/sample-code/) 示例 —
  数据字段结构与 BLE central 写法
- [GoPro Camera Control](https://apps.garmin.com/en-US/apps/b6474aef-4b36-46ea-b7e5-6e8612b50e9d) —
  Garmin 官方 GoPro 遥控（手表-BLE-运动相机通路的先例）

## License

[MIT](LICENSE)
