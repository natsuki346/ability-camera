# Ability Cam

介助者の胸に留めたスマホの背面カメラとマイクで、表情と声の変化をその場で解析する検証用アプリ。

## 確かめたいこと（根本の仮説）
- 映像から表情の変化を、音声の大きさ・高さから状態の変化を、読み取れるか
- それを即時に（撮影→結果の遅れが小さく）出せるか

画面に出る合格の目安：顔が映っている割合 / 解析コマ/秒 / 解析時間 / 撮影→結果の遅れ

## 原則
- 映像と音声は保存しない。外にも送らない（端末の中でその場で解析する）
- 記録（JSONL）にも、動画ファイルにも、リポジトリには入れない（`.gitignore` 済み）
- 医療機器にはしない。「気持ちが分かる」「痛みを検知」とは言わない

## 構成
- `ios/` … iOS アプリ（SwiftUI + MediaPipe Face Landmarker + AVAudioEngine）
- `web/` … ブラウザ版（録画ファイルの解析にも使える）

## iOS のビルド（Mac）
```sh
brew install xcodegen cocoapods
cd ios
TEAM_ID=あなたのチームID ./setup.sh   # モデルの取得 → xcodegen → pod install
open AbilityCam.xcworkspace           # .xcodeproj ではなくこちらを開く
```
iPhone をつないで実行。初回は、iPhone の 設定 > 一般 > VPNとデバイス管理 で開発元を信頼する。

## 記録の形式（`ability-cam.ios.v0`）
1行目はヘッダ。2行目からは1コマ1行：

| キー | 意味 |
|---|---|
| `t_ms` | 撮影時刻（epoch ms）。手首の記録（ability-lab.raw.v1）と並べるときに使う |
| `face` | 顔が見つかったか |
| `bs` | 表情の数値 52種（0〜1） |
| `pts` | 鍵となる顔の点（鼻先・額・あご・両目尻・両口角）[x, y, z] |
| `rms_db` / `f0_hz` | 音量 / 声の高さ |
| `proc_ms` / `lat_ms` | 解析時間 / 撮影→結果の遅れ |
