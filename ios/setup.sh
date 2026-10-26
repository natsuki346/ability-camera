#!/bin/bash
# 使い方: TEAM_ID=あなたのチームID ./setup.sh
# （チームIDは Xcode > Settings > Accounts、または developer.apple.com の Membership で確認）
set -euo pipefail
cd "$(dirname "$0")"

MODEL=AbilityCam/Resources/face_landmarker.task
if [ ! -f "$MODEL" ]; then
  echo "表情解析モデルをダウンロードします…"
  mkdir -p AbilityCam/Resources
  curl -fL -o "$MODEL" https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task
fi

command -v xcodegen >/dev/null || { echo "xcodegen がありません: brew install xcodegen"; exit 1; }
command -v pod >/dev/null      || { echo "CocoaPods がありません: brew install cocoapods"; exit 1; }

export TEAM_ID="${TEAM_ID:-}"
[ -z "$TEAM_ID" ] && echo "注意: TEAM_ID が空です。Xcode の Signing & Capabilities でチームを選んでください。"

xcodegen generate
pod install
echo "完了: open AbilityCam.xcworkspace"
