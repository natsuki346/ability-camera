# xiao-cam（Ability Cam v0 のファームウェア）

Seeed Studio XIAO ESP32S3 Sense 用。胸元の試作機で、静止画と音声を受信側に送り続ける。

- 確かめたいこと：①身につけて撮影・録音・送信が続けられるか ②平均消費電流
- 通信の決まり：[`docs/xiao-protocol-v0.md`](../../docs/xiao-protocol-v0.md)
- 届いた日の確認手順：[`docs/xiao-v0-checklist.md`](../../docs/xiao-v0-checklist.md)

## 何をするか

- 起動 → Wi-Fi につなぐ → `GET /v0/time` で受信側と時刻を合わせる
- 静止画：640×480 JPEG を1秒に1枚 `POST /v0/frame`
- 音声：PDM マイク（GPIO42 クロック／GPIO41 データ）を取り続け、1秒分（32,000 バイト）ごとに `POST /v0/audio`
- Wi-Fi が切れたら自分でつなぎ直す。切れている間のデータは捨てる（ためない・再送しない）
- 映像・音声は本体に保存しない（SD カードは使わない）

## 準備

1. `secrets.example.h` を `secrets.h` にコピーして、Wi-Fi（2.4GHz）・受信側の IP・本体の名前を書く。`secrets.h` は git に入らない
2. ボード：**XIAO_ESP32S3**、**PSRAM：OPI PSRAM**（必須）。ほかは初期値のまま（USB CDC On Boot：Enabled）
   - arduino-esp32 3.x（Espressif の「esp32」ボードパッケージ）

arduino-cli なら：

```sh
cd firmware/xiao-cam
arduino-cli compile --fqbn esp32:esp32:XIAO_ESP32S3:PSRAM=opi .
arduino-cli upload  --fqbn esp32:esp32:XIAO_ESP32S3:PSRAM=opi -p /dev/cu.usbmodem* .
arduino-cli monitor -p /dev/cu.usbmodem* -c baudrate=115200
```

## シリアル（115200）

| 入力 | 意味 |
|---|---|
| `1` | 静止画＋音声 |
| `2` | 静止画のみ |
| `3` | 音声のみ |
| `4` | 待機（Wi-Fi 接続のみ。カメラ・マイクは止める） |

- 選んだモードは本体に覚えさせる。電源を入れ直しても同じモードで始まる（電池につなぐとシリアルが見えないため）
- 起動のとき、モードの番号だけ本体の LED が点滅する（例：モード3なら3回）。その後は消える

10秒ごとに1行出る：

```
[status] up=120s mode=1 wifi=ok rssi=-52 time=ok cam=on mic=on | frame ok=118 fail=0 drop=1 capfail=0 | audio ok=118 fail=0 drop=1 | reconnect=0 heap=... minheap=... psram=...
```

| 項目 | 意味 |
|---|---|
| `ok` / `fail` | 送って 200 が返った数／返らなかった数（つながらない・時間切れを含む） |
| `drop` | 作ったが送らずに捨てた数（Wi-Fi が切れていた・時刻が合っていない・撮れなかった・送信が追いつかなかった） |
| `capfail` | カメラからコマが取れなかった数（`drop` にも入る） |
| `reconnect` | 起動後に Wi-Fi がつながり直した回数 |
| `heap` / `minheap` / `psram` | 空きメモリ（バイト）。`minheap` は起動してからいちばん少なかったとき |
| `cam` / `mic` | `on` 動いている、`off` そのモードでは使わない、`err`／`wait` 使うはずだが動いていない |

`X-Seq` は送れなかった分も進むので、受信側は番号の抜けで届かなかった数を数えられる。
