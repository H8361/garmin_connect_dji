#!/bin/bash
# ============================================================================
# build.sh — CLI 一键构建
# 依赖: Connect IQ SDK (./sdk) + JDK 11+ + 设备库 (~/.Garmin/ConnectIQ/Devices,
#       Windows 为 %APPDATA%\Garmin\ConnectIQ\Devices, 由 SDK Manager 安装)
# 密钥: developer_key.der (PKCS#8 DER 格式; monkeyc 不接受 PEM 文本,
#       可由 openssl 转换, 见下)
# 用法: ./build.sh [设备id]    默认 fr255; 例: ./build.sh fenix7
#
# 注意: 输出文件名必须是 8.3 格式 (主名≤8字符)!
#       Garmin 手表 U 盘安装(GARMIN/APPS)会静默删除长文件名的 PRG — 不装、不报错。
#       应用在手表上显示的名字来自 manifest(@Strings.AppName), 与文件名无关。
# ============================================================================
set -e
cd "$(dirname "$0")"

SDK="${SDK:-./sdk}"
DEVICE="${1:-fr255}"   # 默认按 FR255 构建, 其他机型: ./build.sh fenix7

# JDK: 优先用工程内置 jdk/ (目录名可能带 + 号, 用通配取第一个)
JDK_DIR=$(ls -d ./jdk/jdk-* 2>/dev/null | head -1)
if [ -n "$JDK_DIR" ]; then
    export PATH="$JDK_DIR/bin:$PATH"
fi

KEY=developer_key.der
if [ ! -f "$KEY" ] && [ -f developer_key.pem ]; then
    echo "== 转换 PEM -> PKCS#8 DER (monkeyc 只认 DER) =="
    openssl pkcs8 -topk8 -inform PEM -outform DER -nocrypt \
        -in developer_key.pem -out "$KEY"
fi

MC="$SDK/bin/monkeyc"
[ -x "$MC" ] || MC="$SDK/bin/monkeyc.bat"
OUT=bin
mkdir -p "$OUT"

echo "== 编译数据字段 (datafield) -> $OUT/DJIFIELD.PRG =="
"$MC" -f datafield/monkey.jungle -d "$DEVICE" -y "$KEY" -w -o "$OUT/DJIFIELD.PRG"

echo "== 编译测试 App (testapp) -> $OUT/DJITEST.PRG =="
"$MC" -f testapp/monkey.jungle -d "$DEVICE" -y "$KEY" -w -o "$OUT/DJITEST.PRG"

echo "== 完成 =="
ls -la "$OUT"/*.PRG
# 安装: 把 PRG 拷到手表 U 盘 GARMIN/APPS/ 后安全弹出即可 (文件名须 8.3 格式)
# 日志: 在手表 GARMIN/APPS/LOGS/ 建空文件 DJITEST.TXT 可收集 println 日志
