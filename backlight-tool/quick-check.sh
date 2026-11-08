#!/bin/bash
# 单次 log show，12 分钟窗口：统计 + 把关键的 AGDC/背光内核日志原文存下来
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/safety/quick-check-$(date +%Y%m%d-%H%M%S).txt"
TMP=/tmp/qc.log
sudo log show --last 12m --predicate 'process == "WindowServer" OR process == "kernel"' > "$TMP"
{
  echo "== 时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "== 开机: $(sysctl -n kern.boottime)"
  echo "== 行数: $(wc -l < "$TMP")"
  echo -n "== 内核 Camellia/Banksia: "; grep -ci "camellia\|banksia" "$TMP" || true
  echo -n "== 内核 AGDC/DPMicro: ";      grep -ci "AGDC\|DPMicro" "$TMP" || true
  echo -n "== 内核 brightness/backlight: "; grep -ci "brightness\|backlight" "$TMP" || true
  echo -n "== WindowServer Fallback GPU Pipe failed: "; grep -c "Fallback GPU Display Pipe transaction submission failed" "$TMP" || true
  echo ""
  echo "== 关键日志原文（去重，最多 40 行）=="
  grep -i "AGDC\|DPMicro\|camellia\|banksia\|brightness\|backlight" "$TMP" \
    | sed -E 's/^[0-9-]+ [0-9:.+]+ //' | sort -u | head -40
} > "$OUT"
rm -f "$TMP"
cat "$OUT"
