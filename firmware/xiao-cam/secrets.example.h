// これを secrets.h という名前でコピーして、中身を書き換える。
// secrets.h は git に入れない（firmware/xiao-cam/.gitignore）。
#pragma once

#define WIFI_SSID "your-ssid"          // 2.4GHz の Wi-Fi（ESP32S3 は 5GHz につながらない）
#define WIFI_PASS "your-password"
#define RECEIVER_HOST "192.168.1.10"   // 受信側の IP
#define RECEIVER_PORT 8080
#define DEVICE_ID "xiao-01"
