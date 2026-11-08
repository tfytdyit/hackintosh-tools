#!/bin/bash
# 亮度/显示链路快照：改 ig-platform-id 前后各跑一次，用 diff 对比
# 用法: bash snapshot.sh > snapshot-xxx.txt
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
echo "== 时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "== 系统: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "== 开机: $(sysctl -n kern.boottime)"
echo "== config: $(ls -l /Volumes/EFI/EFI/OC/config.plist 2>/dev/null | awk '{print $5, $(NF-2), $(NF-1), $NF}')"
echo "== ig-platform-id(config): $(python3 - <<'EOF'
import plistlib
try:
    d=plistlib.load(open('/Volumes/EFI/EFI/OC/config.plist','rb'))
    for k,v in d['DeviceProperties']['Add'].items():
        if 'Pci(0x2,0x0)' in k and 'AAPL,ig-platform-id' in v:
            b=v['AAPL,ig-platform-id']
            print(b.hex(), '(0x%08X)' % int.from_bytes(b,'little'))
except Exception as e:
    print('读取失败:', e)
EOF
)"
echo "== AppleIntelFramebuffer 属性:"
ioreg -p IOService -c AppleIntelFramebuffer -r -d 2 2>/dev/null | grep -oE '"(IOFBCurrentPixelClock|IOFBCurrentPixelCount|IOBacklightHandlerID|AAPL,boot-display)" = [^ ]*' | sort -u
echo "== Camellia 相关类实例数:"
ioreg -l 2>/dev/null | grep -oE '"(Camellia[A-Za-z0-9]*|IOFramebufferParameterHandler|AppleIntelPanelA|AppleBacklightDisplay|AGDCBacklightControl)"=[0-9]+' | sort -u
echo "== bklt / 亮度参数:"
echo -n "  "; ioreg -c AppleBacklightDisplay -l 2>/dev/null | grep -o '"bklt"={[^}]*}'
echo "== 亮度链路自检:"
"$DIR/blcheck"
echo "== NVRAM backlight-level: $(nvram backlight-level 2>/dev/null | tr -d '\t' | cut -d' ' -f2-)"
