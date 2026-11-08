#!/bin/bash
WS="$(cd "$(dirname "$0")" && pwd)"
OUT="$WS/safety/cc-diag2-$(date +%Y%m%d-%H%M%S).txt"
JSON="$WS/safety/cc-controls-$(date +%Y%m%d-%H%M%S).json"
mkdir -p "$WS/safety"
{
  echo "== 时间: $(date)"
  echo "== 1) 重启 chronod + ControlCenter（强制重新扫描扩展）"
  sudo killall chronod 2>&1
  sudo killall ControlCenter 2>&1
  sleep 8
  echo "== 2) 解码 Control Center 的「可显示控件」清单"
  python3 - "$JSON" <<'PY'
import plistlib, base64, json, sys, os
p = os.path.expanduser("~/Library/Preferences/com.apple.controlcenter.plist")
d = plistlib.load(open(p,"rb"))
raw = d.get("ControlCenterDisplayableChronoControlsProviderConfiguration")
if raw is None:
    print("没有该 key"); sys.exit()
txt = base64.b64decode(raw).decode("utf-8", "replace") if isinstance(raw,(bytes,bytearray)) else raw
try:
    j = json.loads(txt)
    open(sys.argv[1],"w").write(json.dumps(j, indent=1, ensure_ascii=False))
    print("provider/control 总数:", len(j.get("Controls", j) if isinstance(j,dict) else j))
    s = json.dumps(j, ensure_ascii=False)
    print("包含 BacklightBar:", "BacklightBar" in s, "| 包含 backlightbar:", "backlightbar" in s)
except Exception as e:
    print("JSON 解析失败:", e); open(sys.argv[1],"w").write(txt)
PY
  echo "== 3) chrono 日志（近 3 分钟，含 error/fail/extension）"
  sudo log show --last 3m --style compact --predicate 'subsystem == "com.apple.chrono"' 2>/dev/null | grep -iE "error|fail|reject|extension|scan" | tail -40
  echo "== 4) 与 BacklightBar 相关日志"
  sudo log show --last 3m --style compact --predicate 'eventMessage CONTAINS[c] "BacklightBar"' 2>/dev/null | tail -20
} > "$OUT" 2>&1
echo "已保存: $OUT"
echo "JSON: $JSON"
