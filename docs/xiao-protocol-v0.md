# XIAO v0 の通信の決まり

胸元の試作機（Seeed Studio XIAO ESP32S3 Sense、v0）と受信側の間の決まり。
ファームウェア（`firmware/xiao-cam/`）と受信側（Codex 担当）の両方がこれに従う。

- このファイルは**両方の共通の約束**。片方の都合で変えない。変えたいときは、変えずに理由を添えてユーザーに相談する。
- v0 で確かめるのは2つだけ：①身につけて撮影・録音・送信が続けられるか ②平均消費電流。

## 1. つなぎ方

- 受信側：`http://<受信側のIP>:8080`（HTTP、TLS なし）
- 受信側の IP・Wi-Fi の名前とパスワードは、ファームウェアの `secrets.h` に書く。`secrets.h` は git に入れない
- 本体は受信側と同じ Wi-Fi につなぐ

## 2. 時刻を合わせる：`GET /v0/time`

- 本体は起動時（Wi-Fi につながった直後）に1回呼ぶ
- 受信側は、自分の今の時刻を **エポックミリ秒（UTC、1970-01-01 からのミリ秒）** の10進数テキストで返す
  - 例：`1794471825123`
  - `Content-Type: text/plain`、ステータス 200
- 本体は「受信側の時刻 − 本体の `millis()`」の差を保持し、以後の `X-Captured-Ms` はこの差を足して出す
  - 通信にかかった時間の補正（往復時間の半分を足すなど）は、v0 ではしなくてよい（数十 ms 以内のずれは許す）

## 3. 静止画：`POST /v0/frame`

- 本文：JPEG 1枚（640×480）
- `Content-Type: image/jpeg`
- 本体は 1秒に1枚送る

## 4. 音声：`POST /v0/audio`

- 本文：PCM 符号付き16bit・リトルエンディアン・モノラル・16kHz の **1秒分（16,000 サンプル = 32,000 バイト）**
- `Content-Type: application/octet-stream`
- 本体は 1秒ごとに送る。ヘッダー（WAV など）は付けない

## 5. 共通のヘッダー

| ヘッダー | 中身 | 例 |
|---|---|---|
| `X-Device-Id` | 本体の名前 | `xiao-01` |
| `X-Seq` | 種類ごと（frame／audio それぞれ）の通し番号。起動時に 0 から始め、1つ作るごとに 1 増やす | `42` |
| `X-Captured-Ms` | 受信側の時刻に合わせたエポックミリ秒。静止画は撮った時刻、音声は **1秒分の始まりの時刻** | `1794471825123` |

- `X-Seq` は、送れなかった分・Wi-Fi が切れていて捨てた分も番号を進める。受信側は番号の抜けで「届かなかった数」を数えられる
- 本体を再起動すると `X-Seq` は 0 に戻る

## 6. 返事と失敗

- 受信側は受け取れたら **200** を返す（本文は空でよい）
- 本体は 200 以外・つながらない・時間切れを「失敗」として数えるだけで、**再送はしない**
- Wi-Fi が切れている間のデータは本体にためず捨てる（v0）
- 映像・音声は本体に保存しない（SD カードに書かない）

## 7. 受信側の動作確認に使える例

```sh
# 時刻
curl http://<受信側のIP>:8080/v0/time

# 静止画
curl -X POST --data-binary @test.jpg \
  -H 'Content-Type: image/jpeg' \
  -H 'X-Device-Id: xiao-01' -H 'X-Seq: 0' -H 'X-Captured-Ms: 1794471825123' \
  http://<受信側のIP>:8080/v0/frame

# 音声（32,000 バイトの無音）
head -c 32000 /dev/zero > silence.pcm
curl -X POST --data-binary @silence.pcm \
  -H 'Content-Type: application/octet-stream' \
  -H 'X-Device-Id: xiao-01' -H 'X-Seq: 0' -H 'X-Captured-Ms: 1794471825123' \
  http://<受信側のIP>:8080/v0/audio
```
