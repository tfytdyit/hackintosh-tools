#!/usr/bin/env python3
"""OpenCore config 实验工具（只动 DeviceProperties / boot-args，带自动备份与回滚）
用法:
  sudo python3 oc-experiment.py show
  sudo python3 oc-experiment.py set-platform-id 0900a53e
  sudo python3 oc-experiment.py add-bootarg -wegnoegpu
  sudo python3 oc-experiment.py remove-bootarg -wegnoegpu
  sudo python3 oc-experiment.py restore            # 还原到最早那份备份（= 实验前）
  sudo python3 oc-experiment.py restore-latest     # 撤销最近一次改动
加 --dry-run 只打印不写盘；--config 指定 config.plist 路径。
"""
import argparse
import datetime
import os
import plistlib
import shutil
import struct
import sys

DEFAULT_CONFIG = "/Volumes/EFI/EFI/OC/config.plist"
IGPU_MATCH = "Pci(0x2,0x0)"
NVRAM_GUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
PLATFORM_ID_KEY = "AAPL,ig-platform-id"


def load(path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def save_atomic(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        plistlib.dump(data, f)
    load(tmp)  # 自检：能被重新解析
    os.replace(tmp, path)


def backup(path):
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    dst = f"{path}.bak.{stamp}"
    while os.path.exists(dst):
        stamp += "-1"
        dst = f"{path}.bak.{stamp}"
    shutil.copy2(path, dst)
    return dst


def backups(path):
    d = os.path.dirname(path) or "."
    base = os.path.basename(path) + ".bak."
    return sorted(os.path.join(d, f) for f in os.listdir(d) if f.startswith(base))


def igpu_entry(data):
    add = data.get("DeviceProperties", {}).get("Add", {})
    for key, props in add.items():
        if IGPU_MATCH in key:
            return key, props
    raise SystemExit(f"config 里找不到含 {IGPU_MATCH} 的 DeviceProperties 条目")


def bootargs(data):
    return data.get("NVRAM", {}).get("Add", {}).get(NVRAM_GUID, {}).get("boot-args")


def set_bootargs(data, value):
    nvram = data.setdefault("NVRAM", {}).setdefault("Add", {})
    entry = nvram.setdefault(NVRAM_GUID, {})
    if value:
        entry["boot-args"] = value
    else:
        entry.pop("boot-args", None)


def normalize_platform_id(text):
    text = text.strip().lower().replace("_", "")
    if text.startswith("0x"):
        return struct.pack("<I", int(text, 16))
    raw = bytes.fromhex(text)
    if len(raw) != 4:
        raise SystemExit("platform-id 必须是 4 字节，例如 0900a53e 或 0x3EA50009")
    return raw


def describe(data):
    key, props = igpu_entry(data)
    pid = props.get(PLATFORM_ID_KEY)
    print(f"IGPU 条目录: {key}")
    if isinstance(pid, (bytes, bytearray)):
        print(f"  {PLATFORM_ID_KEY} = {bytes(pid).hex()}  (0x{int.from_bytes(pid, 'little'):08X})")
    else:
        print(f"  {PLATFORM_ID_KEY} = {pid!r}")
    others = {k: v for k, v in props.items() if k != PLATFORM_ID_KEY}
    if others:
        print("  其他 IGPU 属性:")
        for k, v in others.items():
            print(f"    {k} = {v.hex() if isinstance(v, (bytes, bytearray)) else v}")
    print(f"boot-args = {bootargs(data)!r}")


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("command")
    ap.add_argument("value", nargs="?")
    args, extra = ap.parse_known_args()
    # 允许把以 - 开头的 boot-arg（如 -wegnoegpu）直接跟在命令后面，argparse 会把它当选项
    if args.value is None and extra:
        args.value = extra[0]
    elif extra:
        raise SystemExit(f"多余的参数: {extra}")

    path = args.config
    if not os.path.exists(path):
        raise SystemExit(f"找不到 {path}（EFI 没挂载？先执行 sudo diskutil mount disk1s3）")

    data = load(path)

    if args.command == "show":
        describe(data)
        found = backups(path)
        print(f"现有备份 {len(found)} 份" + (f"，最新: {os.path.basename(found[-1])}" if found else ""))
        return

    if args.command == "restore":
        found = backups(path)
        if not found:
            raise SystemExit("没有备份可还原")
        src = found[0]
        print(f"从最早的备份还原: {src}")
        print(f"当前 md5 前内容会先备份一份")
        b = backup(path)
        shutil.copy2(src, path)
        load(path)
        print(f"已还原。刚被替换掉的版本备份在: {b}")
        describe(load(path))
        return

    if args.command == "restore-latest":
        found = backups(path)
        if not found:
            raise SystemExit("没有备份可还原")
        src = found[-1]
        b = backup(path)
        shutil.copy2(src, path)
        load(path)
        print(f"已用 {os.path.basename(src)} 还原（原版本备份: {os.path.basename(b)}）")
        describe(load(path))
        return

    if args.command == "set-platform-id":
        if not args.value:
            raise SystemExit("需要给出 4 字节值，例如 0900a53e")
        new = normalize_platform_id(args.value)
        key, props = igpu_entry(data)
        old = props.get(PLATFORM_ID_KEY)
        print(f"IGPU 条目: {key}")
        if isinstance(old, (bytes, bytearray)):
            print(f"  改前: {bytes(old).hex()}  (0x{int.from_bytes(old, 'little'):08X})")
        print(f"  改后: {new.hex()}  (0x{int.from_bytes(new, 'little'):08X})")
        if bytes(old or b"") == new:
            print("值没变，无需修改。")
            return
        props[PLATFORM_ID_KEY] = new
        if args.dry_run:
            print("--dry-run：不写盘。")
            return
        b = backup(path)
        save_atomic(path, data)
        print(f"已写入 {path}（备份: {b}）")
        print("注意：需要重启才生效；万一开机黑屏，用备份 config.plist 覆盖回去即可。")
        return

    if args.command in ("add-bootarg", "remove-bootarg"):
        if not args.value:
            raise SystemExit("需要给出 boot-arg，例如 -wegnoegpu")
        cur = bootargs(data) or ""
        parts = [p for p in cur.split() if p]
        if args.command == "add-bootarg":
            if args.value in parts:
                print(f"boot-args 里已经有 {args.value}，无需修改。")
                return
            parts.append(args.value)
        else:
            if args.value not in parts:
                print(f"boot-args 里没有 {args.value}，无需修改。")
                return
            parts = [p for p in parts if p != args.value]
        new = " ".join(parts)
        print(f"改前 boot-args: {cur!r}")
        print(f"改后 boot-args: {new!r}")
        if args.dry_run:
            print("--dry-run：不写盘。")
            return
        b = backup(path)
        set_bootargs(data, new)
        save_atomic(path, data)
        print(f"已写入 {path}（备份: {b}）")
        return

    raise SystemExit(f"未知命令: {args.command}")


if __name__ == "__main__":
    main()
