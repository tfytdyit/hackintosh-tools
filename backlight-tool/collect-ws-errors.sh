#!/bin/bash
# 只统计本次开机以来的日志，并按每分钟速率输出，便于和改前的基线比较
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/safety/ws-errors-sinceboot-$(date +%Y%m%d-%H%M%S).txt"
BOOT=$(sysctl -n kern.boottime | sed -E 's/.*sec = ([0-9]+).*/\1/')
START=$(date -r "$BOOT" '+%Y-%m-%d %H:%M:%S')
NOW=$(date +%s)
MIN=$(( (NOW - BOOT) / 60 ))
if [ "$MIN" -lt 1 ]; then MIN=1; fi
TMP=/tmp/ws-sinceboot.log
sudo log show --start "$START" --predicate 'process == "WindowServer"' > "$TMP"
KTMP=/tmp/k-sinceboot.log
sudo log show --start "$START" --predicate 'process == "kernel"' > "$KTMP"
FB=$(grep -c "Fallback GPU Display Pipe transaction submission failed" "$TMP" || true)
IW=$(grep -c "Invalid window" "$TMP" || true)
CE=$(grep -c "CoreDisplay) \[ERROR\]" "$TMP" || true)
BL=$(grep -ci "brightness\|backlight" "$TMP" || true)
KB=$(grep -ci "brightness\|backlight" "$KTMP" || true)
KC=$(grep -ci "camellia\|banksia" "$KTMP" || true)
KA=$(grep -ci "AGDC\|DPMicro" "$KTMP" || true)
{
  echo "== 采集时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "== 开机时间: $START"
  echo "== 距开机: $MIN 分钟"
  echo "== WindowServer 日志行数: $(wc -l < "$TMP")"
  echo "== Fallback GPU Display Pipe failed: $FB  (每分钟 $(awk -v a="$FB" -v m="$MIN" 'BEGIN{printf "%.1f", a/m}'))"
  echo "== CoreDisplay ERROR: $CE  (每分钟 $(awk -v a="$CE" -v m="$MIN" 'BEGIN{printf "%.1f", a/m}'))"
  echo "== SkyLight Invalid window: $IW  (每分钟 $(awk -v a="$IW" -v m="$MIN" 'BEGIN{printf "%.1f", a/m}'))"
  echo "== WindowServer 里 brightness/backlight 行: $BL"
  echo "== 内核日志行数: $(wc -l < "$KTMP")"
  echo "== 内核里 brightness/backlight 行: $KB"
  echo "== 内核里 Camellia/Banksia 行: $KC"
  echo "== 内核里 AGDC/DPMicro 行: $KA"
} > "$OUT"
rm -f "$TMP" "$KTMP"
echo "已写入: $OUT"
