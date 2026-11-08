#!/bin/bash
# 第二轮诊断：先按普通键验证监听权限，再按目标键；最后查 TCC/权限日志
WS="$(cd "$(dirname "$0")" && pwd)"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$WS/safety/keys2-$STAMP.txt"
mkdir -p "$WS/safety"
TMP="$WS/safety/.blkeys-tmp-$STAMP.txt"

cat <<'MSG'
================ 操作顺序（照做即可） ================
马上会出现「监听中（35 秒）」，这 35 秒里请依次做三件事：
  1) 按键 A（就是字母 a）   —— 用来测试监听权限是否正常
  2) 按 F1 键               —— 测试普通 F 键能否被看到
  3) 按你说的那个「亮度键」3 次
======================================================
MSG

"$WS/blkeys" --seconds 35 > "$TMP" 2>&1

{
  echo "== 时间: $(date)"
  echo "== 进程: $(pgrep -lf BacklightBar | head -1)"
  echo "== lastPercent: $(defaults read com.hackintosh.BacklightBar lastPercent 2>/dev/null)"
  echo "== 当前 bklt: $(ioreg -c AppleBacklightDisplay -l 2>/dev/null | grep -o '"bklt"={[^}]*}' | head -1)"
  echo "== blkeys 原始输出:"
  cat "$TMP"
} > "$OUT"
rm -f "$TMP"

echo
echo "== 第三步（可选，看权限是否被拒，会要 sudo 密码）=="
sudo log show --last 5m --predicate 'eventMessage CONTAINS "ListenEvent" OR eventMessage CONTAINS "CGEventTap" OR eventMessage CONTAINS "BacklightBar" OR eventMessage CONTAINS "tapCreate"' 2>/dev/null | tail -25 | tee -a "$OUT"

echo
echo "== 结果已保存: $OUT"
