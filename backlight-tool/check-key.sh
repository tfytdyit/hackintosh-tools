#!/bin/bash
# 检查键盘亮度键是否被 BacklightBar 接管：读当前 bklt，等 25 秒，再读一次
WS="$(cd "$(dirname "$0")" && pwd)"
read_bklt() {
  ioreg -c AppleBacklightDisplay -l 2>/dev/null | grep -o '"bklt"={[^}]*}' | head -1
}
echo "== 现在（请立即去按 3 次键盘亮度键，方向随意，最好按「变暗」两次） =="
echo "bklt: $(read_bklt)"
sleep 25
echo "== 25 秒后 =="
echo "bklt: $(read_bklt)"
echo "百分比: $("$WS/blc" get 2>/dev/null)"
