#!/usr/bin/env python3
"""これまでの記録（sessions.jsonl）の一覧。

アプリはセッション（開いてから閉じるまで）ごとに記録のファイル（ability-cam-*.jsonl、1コマごとの値）を作り、
閉じたときに要約を sessions.jsonl に1行足す（type:"session_summary"）。このスクリプトはその一覧を HTML に出す。
同じフォルダにあるのに要約が無い記録のファイルは、アプリと同じ数え方でここで要約して「要約のない記録」に出す。
外部には何も送らない。

使い方：
  python sessions.py フォルダ                 # フォルダ/sessions.jsonl を読む → フォルダ/sessions.html
  python sessions.py フォルダ/sessions.jsonl --review   # 各記録の振り返りレポート（review.py）も作ってリンクする
"""
from __future__ import annotations

import argparse
import html
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

JST = timezone(timedelta(hours=9), "JST")
YAW_LIMIT = 35.0
RECORD_PREFIX = "ability-cam-"
SESSIONS_NAME = "sessions.jsonl"
NAVY = "#1F3A5F"
BLUE_GRAY = "#5B7FA6"
BAND = "#DCE3EA"


# ---------------------------------------------------------------- 読み込み

def load_sessions(path: Path) -> list[dict]:
    """新しい順。同じファイルの要約が2つあれば後のものを使う"""
    out: dict[str, dict] = {}
    if not path.exists():
        return []
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
            if r.get("type") == "session_summary" and r.get("file"):
                out[r["file"]] = r
    return sorted(out.values(), key=lambda r: -(r.get("started_ms") or 0))


def summarize_record(path: Path) -> dict:
    """記録のファイルから、アプリ（Session.swift の SessionStats）と同じ数え方で要約を作る"""
    first = last = started = None
    frames = 0
    dur = face_s = facing_s = 0.0
    segments = marks = scenes = 0
    active: set[str] = set()
    prev = None   # (t_ms, face, facing)

    def see(t):
        nonlocal first, last
        first = t if first is None or t < first else first
        last = t if last is None or t > last else last

    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue   # 途中で終了された最後の行など
            if not isinstance(r, dict):
                continue
            if "started_at_ms" in r:
                started = r["started_at_ms"]
            t = r.get("t_ms")
            if t is None:
                continue
            if r.get("type") == "frame":
                see(t)
                frames += 1
                face = bool(r.get("face"))
                yaw = r.get("yaw_deg")
                facing = face and yaw is not None and abs(yaw) < YAW_LIMIT
                if prev and t > prev[0]:
                    dt = min((t - prev[0]) / 1000, 1.0)   # 1秒より空いた分は数えない（裏に回っていた間など）
                    dur += dt
                    face_s += dt if prev[1] else 0
                    facing_s += dt if prev[2] else 0
                prev = (t, face, facing)
            elif r.get("type") == "event":
                see(t)
                kind, v = r.get("kind"), r.get("value")
                vals = v if isinstance(v, list) else ([] if v is None else [str(v)])
                if kind == "mark":
                    marks += 1
                elif kind == "scene" and vals and vals[0] != "なし":
                    scenes += 1
                elif kind == "change":
                    keys = set(vals)
                    segments += len(keys - active)
                    active = keys
                elif kind == "baseline_restart":
                    active = set()

    start = started if started is not None else (first or 0)
    end = max(last if last is not None else start, start)
    return {"type": "session_summary", "file": path.name, "started_ms": start, "ended_ms": end, "t_ms": end,
            "duration_s": round(dur, 1), "frames": frames,
            "face_s": round(face_s, 1), "face_ratio": round(face_s / dur, 2) if dur > 0 else None,
            "facing_s": round(facing_s, 1), "facing_ratio": round(facing_s / dur, 2) if dur > 0 else None,
            "yaw_limit_deg": YAW_LIMIT, "segments": segments, "marks": marks, "scenes": scenes}


def unsummarized(folder: Path, sessions: list[dict]) -> list[Path]:
    done = {s["file"] for s in sessions}
    return sorted(p for p in folder.glob(f"{RECORD_PREFIX}*.jsonl") if p.name not in done)


# ---------------------------------------------------------------- HTML

def jst(ms) -> str:
    return "–" if ms is None else datetime.fromtimestamp(ms / 1000, JST).strftime("%Y-%m-%d %H:%M:%S")


def dur(s) -> str:
    if s is None:
        return "–"
    n = int(round(s))
    if n >= 3600:
        return f"{n // 3600}時間{n // 60 % 60:02d}分"
    return f"{n // 60}分{n % 60:02d}秒" if n >= 60 else f"{n}秒"


def pc(x) -> str:
    return "–" if x is None else f"{x:.0%}"


def bar(x, color: str) -> str:
    w = 0 if x is None else max(0.0, min(1.0, x)) * 100
    return (f"<span class=bar><span style='width:{w:.1f}%;background:{color}'></span></span>"
            f"<span class=num>{pc(x)}</span>")


def table(head: list[str], rows: list[list], raw_cols=frozenset()) -> str:
    e = html.escape
    h = "".join(f"<th>{e(x)}</th>" for x in head)
    b = "".join("<tr>" + "".join(f"<td>{x if i in raw_cols else e(str(x))}</td>" for i, x in enumerate(r)) + "</tr>"
                for r in rows)
    return f"<table><thead><tr>{h}</tr></thead><tbody>{b}</tbody></table>"


def rows_for(items: list[dict], folder: Path, links: dict[str, str]) -> list[list]:
    e = html.escape
    out = []
    for s in items:
        f = s["file"]
        if f in links:
            file_cell = f"<a href='{e(links[f])}'>{e(f)}</a>"
        else:
            file_cell = e(f) + ("" if (folder / f).exists() else "（ファイルが見つかりません）")
        out.append([jst(s.get("started_ms")), dur(s.get("duration_s")), bar(s.get("face_ratio"), NAVY),
                    f"{dur(s.get('facing_s'))}（{pc(s.get('facing_ratio'))}）",
                    s.get("segments", "–"), s.get("marks", "–"), s.get("scenes", "–"), file_cell,
                    "次に開いたときに整理" if s.get("recovered") else ""])
    return out


HEAD = ["開始", "長さ", "顔が映っていた割合", f"横を向きすぎていなかった時間（左右{YAW_LIMIT:g}°未満）",
        "変化の区間", "家族の印", "場面", "記録のファイル", "備考"]
RAW = {2, 7}


def render(sessions: list[dict], extra: list[dict], folder: Path, links: dict[str, str]) -> str:
    total = sum(s.get("duration_s") or 0 for s in sessions)
    face = sum(s.get("face_s") or 0 for s in sessions)
    parts = ["<h1>これまでの記録</h1>",
             f"<p class=sub>{html.escape(str(folder))} / {len(sessions)}件 / 合計 {dur(total)}"
             f" / 顔が映っていた割合（時間で重み付け）{pc(face / total if total else None)}</p>",
             "<p class=note>アプリを開いてから閉じるまでを1回の記録（セッション）として、要約を新しい順に並べています。"
             "「変化の区間」は、アプリの画面に「いつもとの違い」が出始めた回数です（振り返りレポートの区間とは基準が違います）。"
             "文言と色は docs/wording-guide.md に従っています。</p>"]
    parts.append("<h2>セッションの一覧</h2>"
                 + (table(HEAD, rows_for(sessions, folder, links), RAW) if sessions else "<p>まだありません。</p>"))
    if extra:
        parts.append("<h2>要約のない記録</h2><p class=note>sessions.jsonl に要約が無い記録のファイルです"
                     "（アプリで次に開いたときに整理されます）。ここではアプリと同じ数え方で要約しています。</p>"
                     + table(HEAD, rows_for(extra, folder, links), RAW))
    css = f"""
    :root{{--fg:#1a1a1a;--sub:#666;--bg:#fff;--line:#ddd}}
    @media (prefers-color-scheme: dark){{:root{{--fg:#eee;--sub:#aaa;--bg:#161616;--line:#333}} a{{color:#9cc3ec}}}}
    body{{font-family:-apple-system,"Hiragino Sans","Yu Gothic",sans-serif;color:var(--fg);background:var(--bg);
         max-width:1200px;margin:24px auto;padding:0 16px;line-height:1.6}}
    h1{{font-size:1.5em;margin-bottom:0}} h2{{font-size:1.15em;margin-top:2em;border-bottom:1px solid var(--line)}}
    .sub{{color:var(--sub);font-size:.9em;margin-top:4px}} .note{{color:var(--sub)}}
    table{{border-collapse:collapse;font-size:.85em;margin:8px 0;display:block;overflow-x:auto}}
    th,td{{border:1px solid var(--line);padding:4px 8px;text-align:left;white-space:nowrap;vertical-align:middle}}
    .bar{{display:inline-block;width:100px;height:10px;background:{BAND};vertical-align:middle;margin-right:6px}}
    .bar>span{{display:block;height:100%}} .num{{font-variant-numeric:tabular-nums}}
    """
    return (f"<!doctype html><html lang=ja><head><meta charset=utf-8>"
            f"<meta name=viewport content='width=device-width,initial-scale=1'><title>これまでの記録</title>"
            f"<style>{css}</style></head><body>{''.join(parts)}</body></html>")


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="これまでの記録（sessions.jsonl）の一覧")
    p.add_argument("path", type=Path, help="sessions.jsonl か、それが入っているフォルダ")
    p.add_argument("--review", action="store_true", help="各記録の振り返りレポート（review.py）も作ってリンクする")
    p.add_argument("--out", type=Path, help="出力する HTML（既定：フォルダ/sessions.html）")
    args = p.parse_args(argv)

    path = args.path / SESSIONS_NAME if args.path.is_dir() else args.path
    folder = path.parent
    sessions = load_sessions(path)
    extra = [summarize_record(f) for f in unsummarized(folder, sessions)]
    extra.sort(key=lambda s: -(s.get("started_ms") or 0))

    links: dict[str, str] = {}
    if args.review:
        import review   # matplotlib を使うので、要るときだけ読む
        for s in sessions + extra:
            rec = folder / s["file"]
            if not rec.exists() or not s.get("frames"):
                continue
            try:
                review.main([str(rec)])
                links[s["file"]] = f"{rec.stem}.html"
            except Exception as ex:   # 1つ読めなくても一覧は出す
                print(f"{rec.name}: レポートを作れませんでした（{ex}）", file=sys.stderr)

    out = args.out or folder / "sessions.html"
    out.write_text(render(sessions, extra, folder, links), encoding="utf-8")
    print(f"セッション {len(sessions)}件（要約のない記録 {len(extra)}件）→ {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
