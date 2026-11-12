# XIAO v0 Mac 受信側

`server.py` は標準ライブラリだけで動く受信専用HTTPサーバーです。固定仕様は [`../docs/xiao-protocol-v0.md`](../docs/xiao-protocol-v0.md) を参照してください。

## 起動

MacとXIAOを同じWi-Fiに接続します。リポジトリのルートで次を実行します。

```sh
python3 receiver/server.py
```

サーバーはポート8080で全ネットワークインターフェースを待ち受けます。XIAOの `secrets.h` に書くMacのWi-Fi側IPアドレスは、macOSの「システム設定 > Wi-Fi > 詳細」または `ipconfig getifaddr en0` で確認できます。VPNや有線LANを使う場合は、XIAOと同じネットワーク側のIPを指定してください。

受信状況は10秒ごとに種類・デバイス別に表示します。

```text
[status] up=10s | audio[xiao-01] received=10 seq_missing=0 seq_resets=0 | frame[xiao-01] received=10 seq_missing=0 seq_resets=0
```

`seq_missing` は、同一デバイス・同一種類で受け取った番号の欠番数です。最初に受け取った番号が0より大きい場合は0からの欠番として数え、以後の番号の飛びも加算します。XIAO再起動による0への戻りは欠番にせず `seq_resets` として表示します。画像・音声の本文は検証後に破棄し、ファイルには保存しません。

終了はサーバーを動かしているターミナルで `Ctrl-C` です。

## curlでの確認

サーバー起動中に別のターミナルを開いて実行します。時刻APIはエポックミリ秒の数字を返します。

```sh
curl -i http://127.0.0.1:8080/v0/time
```

音声エンドポイントには、仕様どおり32,000バイトのPCMデータを送ります。

```sh
head -c 32000 /dev/zero > /tmp/xiao-silence.pcm
curl -i -X POST --data-binary @/tmp/xiao-silence.pcm \
  -H 'Content-Type: application/octet-stream' \
  -H 'X-Device-Id: xiao-01' -H 'X-Seq: 0' \
  -H "X-Captured-Ms: $(date +%s)000" \
  http://127.0.0.1:8080/v0/audio
```

静止画は640×480のJPEGファイルを用意して送ります。

```sh
curl -i -X POST --data-binary @/path/to/test.jpg \
  -H 'Content-Type: image/jpeg' \
  -H 'X-Device-Id: xiao-01' -H 'X-Seq: 0' \
  -H "X-Captured-Ms: $(date +%s)000" \
  http://127.0.0.1:8080/v0/frame
```

有効な要求は `200`、パス違いは `404`、必須ヘッダー・形式・画像寸法（640×480）・音声サイズ（32,000バイト）が仕様に合わない要求は `400` です。frame/audioの `X-Seq` は種類ごとに追跡するため、例のように両方 `0` で送れます。
