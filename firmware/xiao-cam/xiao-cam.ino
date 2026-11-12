// Ability Cam v0：XIAO ESP32S3 Sense のファームウェア
//
// 静止画（640x480 JPEG、1秒に1枚）と音声（PCM 16bit・モノラル・16kHz、1秒ごと）を
// 受信側に HTTP で送る。通信の決まりは docs/xiao-protocol-v0.md。
//
// 確かめたいことは2つだけ：①身につけて撮影・録音・送信が続けられるか ②平均消費電流。
// それ以外は作らない（ため込み・再送・SD 保存はしない）。
//
// ボード設定：XIAO_ESP32S3、PSRAM = OPI PSRAM（必須）
//   arduino-cli の FQBN：esp32:esp32:XIAO_ESP32S3:PSRAM=opi

#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <ESP_I2S.h>
#include "esp_camera.h"
#include "esp_timer.h"
#include "secrets.h"  // secrets.example.h をコピーして作る（git に入れない）

// ---------- 設定 ----------
static const uint32_t FRAME_INTERVAL_MS = 1000;
static const uint32_t STATUS_INTERVAL_MS = 10000;
static const uint32_t AUDIO_RATE = 16000;
static const size_t AUDIO_CHUNK_BYTES = AUDIO_RATE * 2;  // 1秒分 = 32,000 バイト
static const size_t AUDIO_READ_BYTES = 3200;             // 0.1秒ずつ読む
static const int AUDIO_BUF_COUNT = 3;                    // 送信待ちに使う 1秒分のバッファの数
static const uint32_t HTTP_TIMEOUT_MS = 3000;
static const uint32_t WIFI_RETRY_MS = 10000;  // 切れてからこの時間たっても戻らなければ自分でつなぎ直す

// マイク（PDM）
static const int PIN_MIC_CLK = 42;
static const int PIN_MIC_DATA = 41;

// カメラ（XIAO ESP32S3 Sense。arduino-esp32 の CameraWebServer/camera_pins.h と同じ）
#define PWDN_GPIO_NUM -1
#define RESET_GPIO_NUM -1
#define XCLK_GPIO_NUM 10
#define SIOD_GPIO_NUM 40
#define SIOC_GPIO_NUM 39
#define Y9_GPIO_NUM 48
#define Y8_GPIO_NUM 11
#define Y7_GPIO_NUM 12
#define Y6_GPIO_NUM 14
#define Y5_GPIO_NUM 16
#define Y4_GPIO_NUM 18
#define Y3_GPIO_NUM 17
#define Y2_GPIO_NUM 15
#define VSYNC_GPIO_NUM 38
#define HREF_GPIO_NUM 47
#define PCLK_GPIO_NUM 13

#ifndef LED_BUILTIN
#define LED_BUILTIN 21
#endif

// ---------- モード ----------
// 1：静止画＋音声 2：静止画のみ 3：音声のみ 4：待機（Wi-Fi 接続のみ）
enum Mode : uint8_t { MODE_AV = 1, MODE_FRAME = 2, MODE_AUDIO = 3, MODE_IDLE = 4 };
static Mode mode = MODE_AV;
static bool modeHasFrame(Mode m) { return m == MODE_AV || m == MODE_FRAME; }
static bool modeHasAudio(Mode m) { return m == MODE_AV || m == MODE_AUDIO; }

// ---------- 状態 ----------
static Preferences prefs;
static WiFiClient netClient;
static HTTPClient http;

static volatile bool timeSynced = false;
static int64_t timeOffsetMs = 0;  // 受信側のエポックミリ秒 − 本体の起動からのミリ秒
static volatile bool wifiUp = false;

static bool cameraOn = false;
static uint16_t cameraPid = 0;
static volatile bool micWanted = false;
static volatile bool micOn = false;

// 数（それぞれ書き込むのは1つのタスクだけ）
struct Counts {
  uint32_t ok = 0, fail = 0, drop = 0;
};
static Counts frameCnt;
static volatile uint32_t audioDrop = 0;  // 録音タスクが書く
static Counts audioCnt;                  // ok・fail はメインが書く
static uint32_t captureFail = 0;
static uint32_t reconnects = 0;

static uint32_t frameSeq = 0;
static uint32_t audioSeq = 0;  // 録音タスクだけが書く

struct AudioChunk {
  uint8_t *buf;
  uint32_t seq;
  int64_t startLocalMs;
};
static QueueHandle_t audioFree;  // 空いているバッファ
static QueueHandle_t audioFull;  // 送信待ち
static uint8_t *audioDiscard;    // 空きが無いときに読み捨てる先

static inline int64_t localMs() { return esp_timer_get_time() / 1000; }
static inline int64_t toServerMs(int64_t local) { return local + timeOffsetMs; }

// ---------- HTTP ----------
static String baseUrl() {
  return String("http://") + RECEIVER_HOST + ":" + String(RECEIVER_PORT);
}

// 200 なら true。失敗は呼んだ側で数える（再送しない）
static bool postBody(const char *path, const char *contentType, uint8_t *body, size_t len,
                     uint32_t seq, int64_t capturedServerMs) {
  if (!http.begin(netClient, baseUrl() + path)) return false;
  http.setConnectTimeout(HTTP_TIMEOUT_MS);
  http.setTimeout(HTTP_TIMEOUT_MS);
  http.addHeader("Content-Type", contentType);
  http.addHeader("X-Device-Id", DEVICE_ID);
  http.addHeader("X-Seq", String(seq));
  http.addHeader("X-Captured-Ms", String((long long)capturedServerMs));
  int code = http.POST(body, len);
  http.end();
  return code == 200;
}

static bool syncTime() {
  if (!http.begin(netClient, baseUrl() + "/v0/time")) return false;
  http.setConnectTimeout(HTTP_TIMEOUT_MS);
  http.setTimeout(HTTP_TIMEOUT_MS);
  int64_t t0 = localMs();
  int code = http.GET();
  int64_t t1 = localMs();
  bool ok = false;
  if (code == 200) {
    String s = http.getString();
    s.trim();
    char *end = nullptr;
    unsigned long long serverMs = strtoull(s.c_str(), &end, 10);
    if (end != s.c_str() && serverMs > 0) {
      // 往復の真ん中を受信側の時刻に合わせる
      timeOffsetMs = (int64_t)serverMs - (t0 + t1) / 2;
      ok = true;
      Serial.printf("[time] 合わせた offset=%lld ms 往復=%lld ms\n", (long long)timeOffsetMs,
                    (long long)(t1 - t0));
    }
  }
  http.end();
  if (!ok) Serial.printf("[time] 失敗 code=%d\n", code);
  return ok;
}

// ---------- Wi-Fi ----------
static int64_t wifiDownSinceMs = -1;
static bool everConnected = false;

static void wifiBegin() {
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
}

static void wifiMaintain() {
  bool up = WiFi.status() == WL_CONNECTED;
  if (up && !wifiUp) {
    if (everConnected) reconnects++;
    everConnected = true;
    wifiDownSinceMs = -1;
    Serial.printf("[wifi] つながった ip=%s rssi=%d\n", WiFi.localIP().toString().c_str(),
                  WiFi.RSSI());
  } else if (!up && wifiUp) {
    Serial.println("[wifi] 切れた");
  }
  wifiUp = up;

  if (!up) {
    int64_t now = localMs();
    if (wifiDownSinceMs < 0) wifiDownSinceMs = now;
    if (now - wifiDownSinceMs > WIFI_RETRY_MS) {
      Serial.println("[wifi] つなぎ直す");
      WiFi.disconnect();
      WiFi.begin(WIFI_SSID, WIFI_PASS);
      wifiDownSinceMs = now;
    }
    return;
  }

  // 起動時に1回合わせる。失敗したら5秒ごとにやり直す
  static int64_t lastSyncTry = -100000;
  if (!timeSynced && localMs() - lastSyncTry > 5000) {
    lastSyncTry = localMs();
    timeSynced = syncTime();
  }
}

// ---------- カメラ ----------
static bool cameraStart() {
  camera_config_t c = {};
  c.pin_pwdn = PWDN_GPIO_NUM;
  c.pin_reset = RESET_GPIO_NUM;
  c.pin_xclk = XCLK_GPIO_NUM;
  c.pin_sccb_sda = SIOD_GPIO_NUM;
  c.pin_sccb_scl = SIOC_GPIO_NUM;
  c.pin_d7 = Y9_GPIO_NUM;
  c.pin_d6 = Y8_GPIO_NUM;
  c.pin_d5 = Y7_GPIO_NUM;
  c.pin_d4 = Y6_GPIO_NUM;
  c.pin_d3 = Y5_GPIO_NUM;
  c.pin_d2 = Y4_GPIO_NUM;
  c.pin_d1 = Y3_GPIO_NUM;
  c.pin_d0 = Y2_GPIO_NUM;
  c.pin_vsync = VSYNC_GPIO_NUM;
  c.pin_href = HREF_GPIO_NUM;
  c.pin_pclk = PCLK_GPIO_NUM;
  c.xclk_freq_hz = 20000000;
  c.ledc_timer = LEDC_TIMER_0;
  c.ledc_channel = LEDC_CHANNEL_0;
  c.pixel_format = PIXFORMAT_JPEG;
  c.frame_size = FRAMESIZE_VGA;  // 640x480
  c.jpeg_quality = 12;
  c.fb_count = 2;
  c.fb_location = CAMERA_FB_IN_PSRAM;
  c.grab_mode = CAMERA_GRAB_LATEST;  // 1秒に1枚なので、いちばん新しいコマを使う
  esp_err_t err = esp_camera_init(&c);
  if (err != ESP_OK) {
    Serial.printf("[cam] 起動できない err=0x%x\n", err);
    return false;
  }
  sensor_t *s = esp_camera_sensor_get();
  cameraPid = s ? s->id.PID : 0;
  Serial.printf("[cam] 起動 PID=0x%04x (%s)\n", cameraPid,
                cameraPid == OV3660_PID   ? "OV3660"
                : cameraPid == OV5640_PID ? "OV5640"
                                          : "?");
  return true;
}

static void cameraStop() {
  esp_camera_deinit();
  Serial.println("[cam] 止めた");
}

static int64_t nextFrameMs = 0;

static void frameTick() {
  int64_t now = localMs();
  if (now < nextFrameMs) return;
  nextFrameMs += FRAME_INTERVAL_MS;
  if (nextFrameMs <= now) nextFrameMs = now + FRAME_INTERVAL_MS;  // 遅れたら今から数え直す

  uint32_t seq = frameSeq++;
  if (!wifiUp || !timeSynced || !cameraOn) {
    frameCnt.drop++;
    return;
  }
  camera_fb_t *fb = esp_camera_fb_get();
  if (!fb) {
    captureFail++;
    frameCnt.drop++;
    return;
  }
  int64_t capLocal = (int64_t)fb->timestamp.tv_sec * 1000 + fb->timestamp.tv_usec / 1000;
  bool ok = postBody("/v0/frame", "image/jpeg", fb->buf, fb->len, seq, toServerMs(capLocal));
  esp_camera_fb_return(fb);
  if (ok) frameCnt.ok++;
  else frameCnt.fail++;
}

// ---------- マイク（録音タスク） ----------
// I2S はこのタスクだけが触る。メインは micWanted を切り替えるだけ。
static I2SClass i2s;

static void audioTask(void *) {
  AudioChunk cur = {nullptr, 0, 0};
  size_t filled = 0;
  for (;;) {
    if (micWanted && !micOn) {
      i2s.setPinsPdmRx(PIN_MIC_CLK, PIN_MIC_DATA);
      if (i2s.begin(I2S_MODE_PDM_RX, AUDIO_RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO)) {
        micOn = true;
        filled = 0;
        Serial.println("[mic] 起動");
      } else {
        Serial.println("[mic] 起動できない");
        vTaskDelay(pdMS_TO_TICKS(5000));
        continue;
      }
    } else if (!micWanted && micOn) {
      i2s.end();
      micOn = false;
      if (cur.buf) {
        xQueueSend(audioFree, &cur, 0);
        cur.buf = nullptr;
      }
      Serial.println("[mic] 止めた");
    }
    if (!micOn) {
      vTaskDelay(pdMS_TO_TICKS(100));
      continue;
    }

    // 1秒分の始まり：空いているバッファを取る。無ければ読み捨てて数える
    if (filled == 0 && cur.buf == nullptr) {
      if (xQueueReceive(audioFree, &cur, 0) != pdTRUE) cur.buf = nullptr;
    }
    if (cur.buf == nullptr && audioDiscard == nullptr) {  // メモリが取れなかった
      vTaskDelay(pdMS_TO_TICKS(1000));
      continue;
    }
    uint8_t *dst = cur.buf ? cur.buf + filled : audioDiscard + filled;
    size_t n = i2s.readBytes((char *)dst, AUDIO_READ_BYTES);
    filled += n;
    if (filled < AUDIO_CHUNK_BYTES) continue;

    // 1秒分たまった。最後のサンプルが届いた時刻から1秒戻したのを始まりにする
    int64_t startLocal = localMs() - 1000;
    uint32_t seq = audioSeq++;
    filled = 0;
    if (cur.buf == nullptr) {
      audioDrop++;  // 送信が追いつかずバッファが無かった
      continue;
    }
    cur.seq = seq;
    cur.startLocalMs = startLocal;
    if (wifiUp && timeSynced) {
      xQueueSend(audioFull, &cur, 0);  // キューの長さ = バッファの数なので必ず入る
    } else {
      audioDrop++;
      xQueueSend(audioFree, &cur, 0);
    }
    cur.buf = nullptr;
  }
}

static void audioSendPending() {
  AudioChunk c;
  while (xQueueReceive(audioFull, &c, 0) == pdTRUE) {
    bool ok = wifiUp && postBody("/v0/audio", "application/octet-stream", c.buf,
                                 AUDIO_CHUNK_BYTES, c.seq, toServerMs(c.startLocalMs));
    if (ok) audioCnt.ok++;
    else audioCnt.fail++;
    xQueueSend(audioFree, &c, 0);
  }
}

// ---------- モードの切り替え ----------
static void applyMode(Mode m) {
  mode = m;
  bool wantCam = modeHasFrame(m);
  if (wantCam && !cameraOn) cameraOn = cameraStart();
  else if (!wantCam && cameraOn) {
    cameraStop();
    cameraOn = false;
  }
  nextFrameMs = localMs();
  micWanted = modeHasAudio(m);
  Serial.printf("[mode] %d（1=静止画＋音声 2=静止画のみ 3=音声のみ 4=待機）\n", (int)m);
}

static void handleSerial() {
  while (Serial.available()) {
    int ch = Serial.read();
    if (ch >= '1' && ch <= '4') {
      Mode m = (Mode)(ch - '0');
      prefs.putUChar("mode", (uint8_t)m);  // 電源を入れ直しても同じモードで始まる
      applyMode(m);
    }
  }
}

// ---------- 状態の表示 ----------
static void printStatus() {
  Serial.printf(
      "[status] up=%llus mode=%d wifi=%s rssi=%d time=%s cam=%s mic=%s | "
      "frame ok=%u fail=%u drop=%u capfail=%u | audio ok=%u fail=%u drop=%u | "
      "reconnect=%u heap=%u minheap=%u psram=%u\n",
      (unsigned long long)(localMs() / 1000), (int)mode, wifiUp ? "ok" : "down",
      wifiUp ? (int)WiFi.RSSI() : 0, timeSynced ? "ok" : "no",
      modeHasFrame(mode) ? (cameraOn ? "on" : "err") : "off",
      modeHasAudio(mode) ? (micOn ? "on" : "wait") : "off", (unsigned)frameCnt.ok,
      (unsigned)frameCnt.fail, (unsigned)frameCnt.drop, (unsigned)captureFail,
      (unsigned)audioCnt.ok, (unsigned)audioCnt.fail, (unsigned)audioDrop, (unsigned)reconnects,
      (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getMinFreeHeap(), (unsigned)ESP.getFreePsram());
}

// 起動時にモードの番号だけ LED を点滅させる（電池につないでシリアルが見えないときの確認用）
static void blinkMode(int n) {
  pinMode(LED_BUILTIN, OUTPUT);
  for (int i = 0; i < n; i++) {
    digitalWrite(LED_BUILTIN, LOW);  // XIAO の LED は LOW で点く
    delay(200);
    digitalWrite(LED_BUILTIN, HIGH);
    delay(300);
  }
}

static uint8_t *allocBuf(size_t n) {
  uint8_t *p = (uint8_t *)ps_malloc(n);
  if (!p) p = (uint8_t *)malloc(n);
  if (!p) Serial.println("[boot] 音声のバッファを取れない");
  return p;
}

void setup() {
  Serial.begin(115200);
#if ARDUINO_USB_CDC_ON_BOOT && ARDUINO_USB_MODE
  Serial.setTxTimeoutMs(0);  // Mac につないでいないとき（電池のとき）に出力で止まらない
#endif
  delay(1500);
  Serial.println("\n[boot] Ability Cam XIAO v0");
  if (!psramFound()) Serial.println("[boot] PSRAM が無い：ボード設定で OPI PSRAM を有効にする");

  prefs.begin("xiao", false);
  uint8_t m = prefs.getUChar("mode", MODE_AV);
  if (m < MODE_AV || m > MODE_IDLE) m = MODE_AV;
  blinkMode(m);

  audioFree = xQueueCreate(AUDIO_BUF_COUNT, sizeof(AudioChunk));
  audioFull = xQueueCreate(AUDIO_BUF_COUNT, sizeof(AudioChunk));
  audioDiscard = allocBuf(AUDIO_CHUNK_BYTES);
  for (int i = 0; i < AUDIO_BUF_COUNT; i++) {
    AudioChunk c = {allocBuf(AUDIO_CHUNK_BYTES), 0, 0};
    if (c.buf) xQueueSend(audioFree, &c, 0);
  }

  http.setReuse(true);
  wifiBegin();
  applyMode((Mode)m);
  xTaskCreatePinnedToCore(audioTask, "audio", 4096, nullptr, 5, nullptr, 0);
}

void loop() {
  static uint32_t lastStatus = 0;
  handleSerial();
  wifiMaintain();
  if (modeHasFrame(mode)) frameTick();
  audioSendPending();
  if (millis() - lastStatus >= STATUS_INTERVAL_MS) {
    lastStatus = millis();
    printStatus();
  }
  delay(10);
}
