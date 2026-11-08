#!/bin/bash
# 一步收集：App 是否在跑 + 按键识别（blkeys 20 秒）
WS="$(cd "$(dirname "$0")" && pwd)"
OUT="$WS/safety/keys-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$WS/safety"
{
  echo "== 时间: $(date)"
  echo "== BacklightBar 进程:"
  pgrep -lf BacklightBar || echo "(没在跑)"
  echo "== BacklightBar 保存的亮度: $(defaults read com.hackintosh.BacklightBar lastPercent 2>/dev/null)"
  echo "== 当前 bklt: $(ioreg -c AppleBacklightDisplay -l 2>/dev/null | grep -o '"bklt"={[^}]*}' | head -1)"
  echo
  echo "== 下面 20 秒内请按那个亮度键 3 次 =="
  "$WS/blkeys" --seconds 20
} 2>&1 | tee "$OUT"
echo
echo "== 结果已保存: $OUT"
