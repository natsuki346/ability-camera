#!/usr/bin/env python3
"""映り方チェック（framing-checks.jsonl）の一覧と比較。

アプリの「映り方チェック」が残した要約（type:"framing_check"）と、あとから付けたメモ（type:"framing_note"）を読み、
チェックごとの一覧と、顔が映っていた割合の比較の表を HTML に出す。外部には何も送らない。

使い方：python framing.py framing-checks.jsonl [別の端末の framing-checks.jsonl ...] [--out 出力.html]
"""
from __future__ import annotations

import argparse
import html
import json
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

JST = timezone(timedelta(hours=9), "JST")
NAVY = "#1F3A5F"       # 今の値（濃紺）
BLUE_GRAY = "#5B7FA6"
BAND = "#DCE3EA"       # 薄い青灰


@dataclass
class Check:
    d: dict
    note: str = ""

    def __getattr__(self, k):
        return self.d.get(k)


def load(paths: list[Path]) -> list[Check]:
    """要約とメモを読む。同じ id の要約は1つにし、メモは一番新しいものを使う"""
    checks: dict[str, Check] = {}
    notes: dict[str, tuple[int, str]] = {}
    for path in paths:
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    print(f"{path}:{n} 読めない行を飛ばしました", file=sys.stderr)
                    continue
                if r.get("type") == "framing_check" and r.get("id"):
                    checks.setdefault(r["id"], Check(r))
                elif r.get("type") == "framing_note" and r.get("id"):
                    t = int(r.get("t_ms") or 0)
                    if r["id"] not in notes or t >= notes[r["id"]][0]:
                        notes[r["id"]] = (t, str(r.get("note") or ""))
    for i, (_, text) in notes.items():
        if i in checks:
            checks[i].note = text
    return sorted(checks.values(), key=lambda c: c.started_ms or 0)


def groups(checks: list[Check]) -> list[dict]:
    """メモが同じチェックをまとめる。割合は時間で重み付け（長いチェックほど重い）"""
    out: dict[str, dict] = {}
    for c in checks:
        g = out.setdefault(c.note, {"note": c.note, "n": 0, "duration_s": 0.0, "face_s": 0.0, "facing_s": 0.0})
        g["n"] += 1
        g["duration_s"] += c.duration_s or 0
        g["face_s"] += c.face_s or 0
        g["facing_s"] += c.facing_s or 0
    for g in out.values():
        d = g["duration_s"]
        g["face_ratio"] = g["face_s"] / d if d > 0 else None
        g["facing_ratio"] = g["facing_s"] / d if d > 0 else None
    return sorted(out.values(), key=lambda g: -(g["face_ratio"] or 0))


# ---------------------------------------------------------------- HTML

def jst(ms) -> str:
    return "–" if ms is None else datetime.fromtimestamp(ms / 1000, JST).strftime("%Y-%m-%d %H:%M:%S")


def dur(s) -> str:
    if s is None:
        return "–"
    n = int(round(s))
    return f"{n // 60}分{n % 60:02d}秒" if n >= 60 else f"{n}秒"


def pc(x) -> str:
    return "–" if x is None else f"{x:.0%}"


def bar(x, color: str) -> str:
    """割合の横棒（0〜100%）"""
    w = 0 if x is None else max(0.0, min(1.0, x)) * 100
    return (f"<span class=bar><span style='width:{w:.1f}%;background:{color}'></span></span>"
            f"<span class=num>{pc(x)}</span>")


def bins_svg(bins: list, bin_s: float) -> str:
    """10秒ごとの、顔が映っていた割合の小さな棒グラフ"""
    if not bins:
        return "–"
    w, h, gap = 6, 28, 1
    rects = []
    for i, v in enumerate(bins):
        x = i * (w + gap)
        rects.append(f"<rect x={x} y=0 width={w} height={h} fill='{BAND}'/>")
        if v is not None:
            bh = max(0.0, min(1.0, v)) * h
            rects.append(f"<rect x={x} y={h - bh:.1f} width={w} height={bh:.1f} fill='{NAVY}'>"
                         f"<title>{i * bin_s:g}〜{(i + 1) * bin_s:g}秒：{pc(v)}</title></rect>")
    width = len(bins) * (w + gap)
    return f"<svg width={width} height={h} viewBox='0 0 {width} {h}' role=img aria-label='{bin_s:g}秒ごとの割合'>{''.join(rects)}</svg>"


def table(head: list[str], rows: list[list[str]], raw_cols: set[int] = frozenset()) -> str:
    """raw_cols の列は HTML をそのまま入れる（それ以外はエスケープ）"""
    e = html.escape
    h = "".join(f"<th>{e(x)}</th>" for x in head)
    b = "".join("<tr>" + "".join(f"<td>{x if i in raw_cols else e(str(x))}</td>" for i, x in enumerate(r)) + "</tr>"
                for r in rows)
    return f"<table><thead><tr>{h}</tr></thead><tbody>{b}</tbody></table>"


def render(checks: list[Check], sources: list[Path]) -> str:
    e = html.escape
    parts = ["<h1>映り方チェック</h1>",
             f"<p class=sub>{e(' / '.join(p.name for p in sources))} / {len(checks)}件</p>",
             "<p class=note>カメラに顔がどのくらいの時間映っていたかを確かめるための記録です。"
             "要約だけで、1コマごとの値・表情の数値・顔の点は含みません。文言と色は docs/wording-guide.md に従っています。</p>"]
    if not checks:
        parts.append("<p>映り方チェックの記録がありません。</p>")
        return page(parts)

    limit = next((c.yaw_limit_deg for c in checks if c.yaw_limit_deg), 35)

    # 比較の表（メモごと）
    g = groups(checks)
    rows = [[x["note"] or "（メモなし）", x["n"], dur(x["duration_s"]), bar(x["face_ratio"], NAVY),
             bar(x["facing_ratio"], BLUE_GRAY)] for x in g]
    parts.append("<h2>映っていた割合の比較（メモごと）</h2>"
                 "<p class=note>同じメモのチェックをまとめ、時間で重み付けした割合です（長いチェックほど重く数えます）。</p>"
                 + table(["メモ", "件数", "合計の時間", "顔が映っていた", f"横を向きすぎていなかった（左右{limit:g}°未満）"],
                         rows, {3, 4}))

    rows = [[c.note or "（メモなし）", jst(c.started_ms), dur(c.duration_s), bar(c.face_ratio, NAVY),
             bar(c.facing_ratio, BLUE_GRAY), bins_svg(c.bin_face_ratio or [], c.bin_s or 10)]
            for c in sorted(checks, key=lambda c: -(c.face_ratio or 0))]
    parts.append("<h2>映っていた割合の比較（チェックごと）</h2>"
                 + table(["メモ", "開始", "時間", "顔が映っていた", "横を向きすぎていなかった", "10秒ごとの、顔が映っていた割合"],
                         rows, {3, 4, 5}))

    # 一覧（時刻順）
    rows = [[jst(c.started_ms), jst(c.ended_ms), dur(c.duration_s),
             f"{dur(c.face_s)}（{pc(c.face_ratio)}）", f"{dur(c.facing_s)}（{pc(c.facing_ratio)}）",
             dur(c.longest_no_face_s),
             "–" if c.fps_mean is None else f"{c.fps_mean:.1f}",
             "–" if c.mesh_lag_ms_median is None else f"{c.mesh_lag_ms_median:.0f}",
             "アプリが裏に回った" if c.ended_by == "background" else "ボタン",
             c.note or "", c.device or ""] for c in checks]
    parts.append("<h2>チェックの一覧</h2>"
                 + table(["開始", "終了", "計測した時間", "顔が映っていた時間", "横を向きすぎていなかった時間",
                          "映らなかった時間の一番長い続き", "解析コマ/秒（平均）", "撮影→網目 ms（中央値）",
                          "終え方", "メモ", "端末"], rows))
    return page(parts)


def page(parts: list[str]) -> str:
    css = f"""
    :root{{--fg:#1a1a1a;--sub:#666;--bg:#fff;--line:#ddd}}
    @media (prefers-color-scheme: dark){{:root{{--fg:#eee;--sub:#aaa;--bg:#161616;--line:#333}}}}
    body{{font-family:-apple-system,"Hiragino Sans","Yu Gothic",sans-serif;color:var(--fg);background:var(--bg);
         max-width:1200px;margin:24px auto;padding:0 16px;line-height:1.6}}
    h1{{font-size:1.5em;margin-bottom:0}} h2{{font-size:1.15em;margin-top:2em;border-bottom:1px solid var(--line)}}
    .sub{{color:var(--sub);font-size:.9em;margin-top:4px}} .note{{color:var(--sub)}}
    table{{border-collapse:collapse;font-size:.85em;margin:8px 0;display:block;overflow-x:auto}}
    th,td{{border:1px solid var(--line);padding:4px 8px;text-align:left;white-space:nowrap;vertical-align:middle}}
    .bar{{display:inline-block;width:120px;height:10px;background:{BAND};vertical-align:middle;margin-right:6px}}
    .bar>span{{display:block;height:100%}}
    .num{{font-variant-numeric:tabular-nums}}
    svg{{vertical-align:middle}}
    """
    return (f"<!doctype html><html lang=ja><head><meta charset=utf-8>"
            f"<meta name=viewport content='width=device-width,initial-scale=1'><title>映り方チェック</title>"
            f"<style>{css}</style></head><body>{''.join(parts)}</body></html>")


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="映り方チェック（framing-checks.jsonl）の一覧と比較")
    p.add_argument("jsonl", type=Path, nargs="+")
    p.add_argument("--out", type=Path, help="出力する HTML（既定：1つ目の入力と同じ場所の <名前>.html）")
    args = p.parse_args(argv)
    checks = load(args.jsonl)
    out = args.out or args.jsonl[0].with_suffix(".html")
    out.write_text(render(checks, args.jsonl), encoding="utf-8")
    print(f"映り方チェック {len(checks)}件 → {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
