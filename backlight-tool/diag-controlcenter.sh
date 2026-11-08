#!/bin/bash
WS="$(cd "$(dirname "$0")" && pwd)"
OUT="$WS/safety/cc-diag-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$WS/safety"
{
  echo "== 时间: $(date)"
  echo "== 1) 重启控制中心进程"
  sudo killall ControlCenter 2>/dev/null && echo "ControlCenter 已重启" || echo "ControlCenter 重启失败/不需要"
  sleep 3
  echo
  echo "== 2) 扩展注册状态（-v 详情）"
  pluginkit -m -v -i com.hackintosh.BacklightBar.controls 2>&1
  echo
  echo "== 3) 所有 widgetkit 扩展（前 20 行）"
  pluginkit -m -p com.apple.widgetkit-extension 2>&1 | head -20
  echo
  echo "== 4) App 与扩展的签名"
  codesign -dv /Applications/BacklightBar.app 2>&1 | head -6
  codesign -dv /Applications/BacklightBar.app/Contents/PlugIns/BacklightBarControls.appex 2>&1 | head -8
  echo
  echo "== 5) 系统日志（近 15 分钟，含 BacklightBar / widget / Controls）"
  sudo log show --last 15m --style compact --predicate 'eventMessage CONTAINS[c] "BacklightBar" OR eventMessage CONTAINS[c] "widgetkit" OR eventMessage CONTAINS[c] "controls"' 2>/dev/null | grep -v "^Timestamp" | tail -60
} > "$OUT" 2>&1
echo
echo "== 已保存: $OUT"
echo "== 现在请再打开一次「控制中心 → 编辑控制项」看看有没有 BacklightBar"
