#!/usr/bin/env python3
"""家族の印に、あとから「詳しい中身」を付ける・変える・消す（v1.13〜、Mac で）。

記録のファイル（JSONL）の家族の印の行（type: "event"、kind: "mark"）に detail（家族の言葉）と detail_at（付けた時刻）を書く。
ほかの行は変えない。詳しい中身は家族の言葉としてそのまま書くもので、アプリやレポートが本人の状態として判定・表示には使わない（docs/wording-guide.md）。

使い方：
  python mark_detail.py 記録.jsonl                       家族の印の一覧（番号・時刻・印・詳しい中身）と、選択肢（記録のヘッダの mark_details）
  python mark_detail.py 記録.jsonl --set 2 姿勢がつらそう  2番の印に詳しい中身を付ける（変える）
  python mark_detail.py 記録.jsonl --clear 2              2番の印の詳しい中身を消す
「分からない」の印には付けない。選択肢に無い言葉も付けられる（家族の言葉として）が、そのときは知らせる
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from pathlib import Path

import review

INITIAL = {"快": ["楽しそう", "落ち着いている", "好きなもの・人", "その他"],
           "不快": ["お腹がすいた", "トイレ", "痛そう", "暑い・寒い", "姿勢がつらそう", "眠そう", "その他"]}


def read(path: Path) -> tuple[list[str], dict, list[tuple[int, dict]]]:
    """返り値：(行, ヘッダ, [(行の番号, 印の行)]（時刻の順）)"""
    lines = path.read_text(encoding="utf-8").split("\n")
    header: dict = {}
    marks = []
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            continue
        if i == 0 and "schema" in o:
            header = o
        elif o.get("type") == "event" and o.get("kind") == "mark":
            marks.append((i, o))
    marks.sort(key=lambda x: x[1]["t_ms"])
    return lines, header, marks


def options(header: dict) -> dict[str, list[str]]:
    return header.get("mark_details") or INITIAL


def amend(path: Path, number: int, detail: str | None, now_ms: int | None = None) -> dict:
    """number 番（1から）の印に詳しい中身を書く（None で消す）。書いた印の行を返す。ファイルは置き換えて書く"""
    lines, header, marks = read(path)
    if not 1 <= number <= len(marks):
        raise SystemExit(f"{number}番の家族の印はありません（1〜{len(marks)}）")
    i, o = marks[number - 1]
    if o.get("value") == "分からない" and detail is not None:
        raise SystemExit("「分からない」の印には詳しい中身を付けません")
    if detail is None:
        o.pop("detail", None)
        o.pop("detail_at", None)
    else:
        o["detail"] = detail
        o["detail_at"] = now_ms if now_ms is not None else int(time.time() * 1000)
    lines[i] = json.dumps(o, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".mark_detail-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    os.replace(tmp, path)
    return o


def listing(path: Path) -> list[str]:
    _, header, marks = read(path)
    out = [f"{path.name}：家族の印 {len(marks)}件"]
    for n, (_, o) in enumerate(marks, 1):
        by = f"（{o.get('by') or '見る側'}で）" if o.get("source") == "viewer" else ""
        d = f"・{o['detail']}" if o.get("detail") else ""
        at = f"（付けた時刻 {review.jst(o['detail_at'] / 1000)}）" if o.get("detail_at") else ""
        out.append(f"{n}. {review.jst(o['t_ms'] / 1000)} 家族の印：{o.get('value')}{d}{by}{at}")
    for k, v in options(header).items():
        out.append(f"選択肢（{k}）：" + "・".join(v))
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("record")
    ap.add_argument("--set", nargs=2, metavar=("番号", "詳しい中身"))
    ap.add_argument("--clear", type=int, metavar="番号")
    args = ap.parse_args(argv)
    path = Path(args.record)
    if args.set:
        number, detail = int(args.set[0]), args.set[1].strip()
        _, header, marks = read(path)
        if 1 <= number <= len(marks) and detail not in options(header).get(marks[number - 1][1].get("value"), []):
            print(f"「{detail}」は選択肢にありませんが、家族の言葉としてそのまま書きます")
        o = amend(path, number, detail)
        print(f"{number}. {review.jst(o['t_ms'] / 1000)} 家族の印：{o['value']}・{detail} を書きました")
    elif args.clear:
        o = amend(path, args.clear, None)
        print(f"{args.clear}. {review.jst(o['t_ms'] / 1000)} 家族の印：{o['value']} の詳しい中身を消しました")
    else:
        print("\n".join(listing(path)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
