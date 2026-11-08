#!/usr/bin/env python3
"""Gadgetbridge 数据库导入器（只读，不改原文件）。

用法：
  python3 gbimport.py list  gadgetbridge.db          # 列出所有表 / 字段 / 行数
  python3 gbimport.py dump  gadgetbridge.db          # 打印疑似健康数据表的样例
  python3 gbimport.py days  gadgetbridge.db [N]      # 最近 N 天的步数 / 心率 / 睡眠汇总
  python3 gbimport.py json  gadgetbridge.db out.json # 导出成 SensorBar 用的 JSON

Gadgetbridge 的导出文件是 SQLite（gadgetbridge.db）；华为设备的数据表一般叫
HUAWEI_ACTIVITY_SAMPLE，小米是 MI_BAND_ACTIVITY_SAMPLE，另外还有
ACTIVITY_SAMPLE / HEART_RATE_SAMPLE / DEVICE / USER 等。不同版本表名会变，
所以这里全部用「探测 + 容错」的方式，不硬编码。
"""
import json
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

HEALTH_TABLES = [
    "HUAWEI_ACTIVITY_SAMPLE", "MI_BAND_ACTIVITY_SAMPLE", "ACTIVITY_SAMPLE",
    "HEART_RATE_SAMPLE", "STRESS_SAMPLE", "SPO2_SAMPLE", "SLEEP_SESSION_SAMPLE",
    "DEVICE", "USER", "DEVICE_ATTRIBUTES", "ALARM",
]


def resolve_db(path):
    """Gadgetbridge 导出的 zip 里是一个没有扩展名的 SQLite 文件 `Gadgetbridge`。"""
    if path.lower().endswith(".zip"):
        import tempfile, zipfile
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist()
                     if n.split("/")[-1] in ("Gadgetbridge", "gadgetbridge.db")
                     or n.lower().endswith(".db")]
            if not names:
                names = [n for n in z.namelist() if "/" not in n and not n.lower().endswith((".gpx", ".xml"))]
            if not names:
                sys.exit("zip 里找不到数据库文件")
            tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".db")
            tmp.write(z.read(names[0]))
            tmp.close()
            print(f"（已从 zip 解出 {names[0]}）")
            return tmp.name
    return path


def open_db(path):
    con = sqlite3.connect(f"file:{resolve_db(path)}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def tables(con):
    return [r[0] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]


def columns(con, t):
    return [r[1] for r in con.execute(f'PRAGMA table_info("{t}")')]


def cmd_list(con, _args):
    ts = tables(con)
    print(f"共 {len(ts)} 张表\n")
    for t in ts:
        try:
            n = con.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
        except sqlite3.DatabaseError:
            n = -1
        flag = "  ← 健康数据" if t.upper() in HEALTH_TABLES else ""
        print(f"{t:38s} {n:>8d} 行   {', '.join(columns(con, t))}{flag}")


def cmd_dump(con, _args):
    for t in tables(con):
        if t.upper() not in HEALTH_TABLES:
            continue
        n = con.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
        if n == 0:
            continue
        print(f"\n===== {t}（{n} 行）=====")
        print("字段:", ", ".join(columns(con, t)))
        for r in con.execute(f'SELECT * FROM "{t}" LIMIT 5'):
            print("  ", {k: r[k] for k in r.keys()})


def _epoch_to_dt(v):
    if v is None:
        return None
    v = int(v)
    if v > 10_000_000_000:      # 毫秒
        v //= 1000
    return datetime.fromtimestamp(v, tz=timezone.utc)


def cmd_days(con, args):
    days = int(args[0]) if args else 7
    since = (datetime.now(timezone.utc) - timedelta(days=days)).timestamp()
    print(f"最近 {days} 天")

    # 心率
    for tbl, tcol, vcol in [
        ("HUAWEI_ACTIVITY_SAMPLE", "TIMESTAMP", "HEART_RATE"),
        ("MI_BAND_ACTIVITY_SAMPLE", "TIMESTAMP", "HEART_RATE"),
        ("HEART_RATE_SAMPLE", "TIMESTAMP", "HEART_RATE"),
        ("ACTIVITY_SAMPLE", "TIMESTAMP", "HEART_RATE"),
    ]:
        if tbl not in tables(con):
            continue
        cols = [c.upper() for c in columns(con, tbl)]
        if tcol not in cols or vcol not in cols:
            continue
        rows = con.execute(
            f'SELECT "{tcol}" AS ts, "{vcol}" AS v FROM "{tbl}" '
            f'WHERE "{tcol}" >= ? AND "{vcol}" > 0 ORDER BY "{tcol}"', (int(since),)).fetchall()
        if not rows:
            continue
        vals = [r["v"] for r in rows]
        print(f"  心率[{tbl}]: {len(vals)} 个点  min={min(vals)} avg={sum(vals)//len(vals)} max={max(vals)}")
        break

    # 睡眠（华为：RAW_KIND 6=浅睡 7=深睡；SOURCE 10=TruSleep 13=活动睡眠）
    tbl = "HUAWEI_ACTIVITY_SAMPLE"
    if tbl in tables(con):
        cols = [c.upper() for c in columns(con, tbl)]
        if "RAW_KIND" in cols and "TIMESTAMP" in cols:
            rows = con.execute(
                f'SELECT TIMESTAMP AS ts, RAW_KIND AS k, SOURCE AS s FROM "{tbl}" '
                f'WHERE TIMESTAMP >= ? AND RAW_KIND IN (6, 7) ORDER BY TIMESTAMP',
                (int(since),)).fetchall()
            if rows:
                # 合并连续区间（相邻样本间隔 < 15 分钟视为同一段睡眠）
                sessions = []
                cur_start = cur_end = None
                cur_kinds = set()
                for r in rows:
                    ts = int(r["ts"])
                    if cur_start is None:
                        cur_start = cur_end = ts
                        cur_kinds = {int(r["k"])}
                    elif ts - cur_end <= 900:
                        cur_end = ts
                        cur_kinds.add(int(r["k"]))
                    else:
                        sessions.append((cur_start, cur_end, cur_kinds))
                        cur_start = cur_end = ts
                        cur_kinds = {int(r["k"])}
                if cur_start is not None:
                    sessions.append((cur_start, cur_end, cur_kinds))
                print(f"  睡眠[{tbl}]: {len(sessions)} 段")
                for st, en, kinds in sessions[-5:]:
                    d = _epoch_to_dt(st).astimezone().strftime("%m-%d %H:%M")
                    mins = max(0, (en - st) // 60) + 10
                    tags = "深睡" if kinds == {7} else ("浅睡" if kinds == {6} else "深浅混合")
                    print(f"    {d}  约 {mins // 60}h{mins % 60:02d}m  {tags}")

    # 步数
    for tbl in ("HUAWEI_ACTIVITY_SAMPLE", "MI_BAND_ACTIVITY_SAMPLE", "ACTIVITY_SAMPLE"):
        if tbl not in tables(con):
            continue
        cols = [c.upper() for c in columns(con, tbl)]
        if "STEPS" not in cols:
            continue
        tcol = "TIMESTAMP" if "TIMESTAMP" in cols else None
        if not tcol:
            continue
        rows = con.execute(
            f'SELECT "{tcol}" AS ts, STEPS FROM "{tbl}" WHERE "{tcol}" >= ? ORDER BY "{tcol}"',
            (int(since),)).fetchall()
        if rows:
            per_day = {}
            for r in rows:
                d = _epoch_to_dt(r["ts"]).strftime("%Y-%m-%d")
                per_day[d] = per_day.get(d, 0) + int(r["STEPS"] or 0)
            print(f"  步数[{tbl}]:")
            for d in sorted(per_day):
                print(f"    {d}  {per_day[d]:>6d} 步  {'█' * min(40, per_day[d] // 300)}")
            break


def cmd_json(con, args):
    out = args[0] if args else "gb-health.json"
    data = {"exported_at": datetime.now(timezone.utc).isoformat(), "days": {}}
    since = (datetime.now(timezone.utc) - timedelta(days=30)).timestamp()
    for tbl in ("HUAWEI_ACTIVITY_SAMPLE", "MI_BAND_ACTIVITY_SAMPLE", "ACTIVITY_SAMPLE"):
        if tbl not in tables(con):
            continue
        cols = [c.upper() for c in columns(con, tbl)]
        if "TIMESTAMP" not in cols:
            continue
        sel = ['"TIMESTAMP" AS ts']
        sel.append("STEPS" if "STEPS" in cols else "0 AS STEPS")
        sel.append("HEART_RATE" if "HEART_RATE" in cols else "0 AS HEART_RATE")
        sel.append("SPO" if "SPO" in cols else ("SPO2" if "SPO2" in cols else "0 AS SPO"))
        sel.append("RAW_KIND" if "RAW_KIND" in cols else "0 AS RAW_KIND")
        for r in con.execute(
                f'SELECT {", ".join(sel)} FROM "{tbl}" WHERE "TIMESTAMP" >= ? ORDER BY "TIMESTAMP"',
                (int(since),)):
            d = _epoch_to_dt(r["ts"]).strftime("%Y-%m-%d")
            slot = data["days"].setdefault(d, {"steps": 0, "hr": [], "spo": [], "sleep_min": 0})
            slot["steps"] += int(r["STEPS"] or 0)
            if r["HEART_RATE"]:
                slot["hr"].append(int(r["HEART_RATE"]))
            if r["SPO"]:
                slot["spo"].append(int(r["SPO"]))
            if int(r["RAW_KIND"] or 0) in (6, 7):
                slot["sleep_min"] += 10
        data["source_table"] = tbl
        break
    with open(out, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    print(f"已写出 {out}（{len(data['days'])} 天）")


def autodiscover():
    """在脚本所在目录里找最新的 Gadgetbridge 导出（zip 或 sqlite）。"""
    import os, glob
    here = os.path.dirname(os.path.abspath(__file__))
    cands = []
    for pat in ("*.zip", "Gadgetbridge*", "gadgetbridge*", "*.db", "*.sqlite"):
        cands += glob.glob(os.path.join(here, pat))
    cands = [c for c in cands if os.path.isfile(c)]
    if not cands:
        return None
    cands.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return cands[0]


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    cmd = args[0]
    rest = args[1:]
    def looks_like_db(p):
        low = os.path.basename(p).lower()
        return (os.path.exists(p) or low.endswith((".zip", ".db", ".sqlite"))
                or low.startswith("gadgetbridge"))

    if rest and looks_like_db(rest[0]):
        path, rest = rest[0], rest[1:]
    else:
        path = autodiscover()
        if not path:
            sys.exit("没找到导出文件。把 Gadgetbridge 的 zip（或里面的 SQLite 文件）"
                     f"放到 {os.path.dirname(os.path.abspath(__file__))}/ 再跑一次，"
                     "或者直接给路径：python3 gbimport.py list /path/to/Gadgetbridge.zip")
        print(f"（自动找到：{path}）")
    con = open_db(path)
    {"list": cmd_list, "dump": cmd_dump, "days": cmd_days, "json": cmd_json}[cmd](con, rest)


if __name__ == "__main__":
    main()
