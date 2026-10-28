#!/bin/bash
# 使い方: TEAM_ID=あなたのチームID ./setup.sh
# （チームIDは Xcode > Settings > Accounts、または developer.apple.com の Membership で確認）
# 何度動かしても同じ結果になる（2回目は、前に作ったプロジェクトのチームIDをそのまま使う）
set -euo pipefail
cd "$(dirname "$0")"

# 1. 古い複製（「AbilityCam 2.xcodeproj」のように、名前に空白と数字が付いたもの）をゴミ箱へ。
#    残っていると Xcode やワークスペースがそちらを開き、新しいファイルが入っていないためビルドが失敗する
shopt -s nullglob
for dup in "AbilityCam "*.xcodeproj "AbilityCam "*.xcworkspace; do
  dest="$HOME/.Trash/$dup"
  [ -e "$dest" ] && dest="$HOME/.Trash/${dup%.*} $(date +%Y%m%d-%H%M%S).${dup##*.}"
  echo "古い複製をゴミ箱に移します: ios/${dup}"
  mv "$dup" "$dest"
done
shopt -u nullglob

MODEL=AbilityCam/Resources/face_landmarker.task
if [ ! -f "$MODEL" ]; then
  echo "表情解析モデルをダウンロードします…"
  mkdir -p AbilityCam/Resources
  curl -fL -o "$MODEL" https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task
fi

# 話者の区別のモデル（v1.10〜）：WeSpeaker ResNet34-LM（pyannote/wespeaker-voxceleb-resnet34-LM）を Fluid Inference が Core ML に変換したもの。
# CC BY 4.0（README の「ライセンス」）。変わっていないかを sha256 で確かめる
SPK=AbilityCam/Resources/wespeaker.mlmodelc
SPK_URL=https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/main/wespeaker.mlmodelc
SPK_SHA=680837ec172d67c3197bba93800e1623eebfd35c3b17011802f5f98b8026a0aa
if [ ! -f "$SPK/weights/weight.bin" ]; then
  echo "話者の区別のモデルをダウンロードします…"
  mkdir -p "$SPK/weights" "$SPK/analytics"
  for f in coremldata.bin metadata.json model.mil weights/weight.bin analytics/coremldata.bin; do
    curl -fL -o "$SPK/$f" "$SPK_URL/$f"
  done
fi
echo "$SPK_SHA  $SPK/weights/weight.bin" | shasum -a 256 -c - >/dev/null || { echo "エラー: 話者の区別のモデルの中身が違います（$SPK を消して、もう一度 setup.sh）"; exit 1; }

command -v xcodegen >/dev/null || { echo "xcodegen がありません: brew install xcodegen"; exit 1; }
command -v pod >/dev/null      || { echo "CocoaPods がありません: brew install cocoapods"; exit 1; }

# 2. チームID：指定が無ければ、前に作ったプロジェクトのものを使う（空のまま作り直して署名が外れないように）
TEAM_ID="${TEAM_ID:-}"
if [ -z "$TEAM_ID" ] && [ -f AbilityCam.xcodeproj/project.pbxproj ]; then
  TEAM_ID=$(grep -m1 -o 'DEVELOPMENT_TEAM = [A-Z0-9]*' AbilityCam.xcodeproj/project.pbxproj | sed 's/.*= //' || true)
  [ -n "$TEAM_ID" ] && echo "チームID: 前のプロジェクトの ${TEAM_ID} を使います"
fi
export TEAM_ID
[ -z "$TEAM_ID" ] && echo "注意: TEAM_ID が空です。Xcode の Signing & Capabilities でチームを選んでください。"

# 3. プロジェクトとワークスペースを作り直す（ワークスペースは消してから作るので、古い参照が残らない）
xcodegen generate
rm -rf AbilityCam.xcworkspace
pod install

# 4. ワークスペースが参照しているのが AbilityCam.xcodeproj と Pods/Pods.xcodeproj の2つだけか
DATA=AbilityCam.xcworkspace/contents.xcworkspacedata
[ -f "$DATA" ] || { echo "エラー: $DATA がありません（pod install が失敗しています）"; exit 1; }
refs=$(sed -n 's/.*location = "\([^"]*\)".*/\1/p' "$DATA" | sort | tr '\n' ' ')
want="group:AbilityCam.xcodeproj group:Pods/Pods.xcodeproj "
if [ "$refs" != "$want" ]; then
  echo "エラー: ワークスペースの参照が違います: ${refs}（期待: ${want}）"
  exit 1
fi

echo "完了: ワークスペースの参照は AbilityCam.xcodeproj と Pods/Pods.xcodeproj の2つです"
echo "Xcode を開いていたら ⌘Q で閉じてから open AbilityCam.xcworkspace"
