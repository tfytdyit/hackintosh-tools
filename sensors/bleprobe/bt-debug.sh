#!/bin/bash
# 蓝牙 LE 连接诊断：一边尝试连接手环，一边抓 bluetoothd 日志
# 用法：bash "$(cd "$(dirname "$0")" && pwd)/bt-debug.sh"
WS="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WS/sensors/bleprobe" || exit 1

pkill -f "./simple" 2>/dev/null
rm -f /tmp/ble-simple.txt

echo "==> 1/3 启动探测（会尝试连接广播 180D 的手环，约 55 秒）"
./simple > /tmp/bt-probe-out.txt 2>&1 &
PID=$!

sleep 14
echo "==> 2/3 抓取最近 40 秒的蓝牙系统日志（需要输入密码）"
sudo log show --last 40s --predicate 'subsystem == "com.apple.bluetooth"' --style compact \
    > "$WS/bt-le.log" 2>&1

wait $PID

echo
echo "==> 3/3 探测结果"
cat /tmp/ble-simple.txt 2>/dev/null

echo
echo "==> 蓝牙日志里的关键行（共 $(wc -l < "$WS/bt-le.log" 2>/dev/null || echo 0) 行）"
grep -iE "error|fail|timeout|disconnect|LE_|connect" "$WS/bt-le.log" 2>/dev/null | head -40

echo
echo "完整日志已保存：$WS/bt-le.log"
