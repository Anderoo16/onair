// Seeed Studio XIAO ESP32-C3, Arduino ESP32 core 3.3.7.
// D2 / GPIO4 connects to Adafruit 5648 In. Provision Wi-Fi over USB.
#include <ESPmDNS.h>
#include <Preferences.h>
#include <WebServer.h>
#include <WiFi.h>

namespace {
constexpr uint8_t outputPin = D2;
static_assert(outputPin == 4, "Select XIAO_ESP32C3 as the Arduino board.");
constexpr unsigned leaseMs = 15000;
constexpr uint16_t port = 8765;
constexpr char keyHeader[] = "X-On-Air-Key";

struct Config {
  char ssid[33];
  char password[64];
  char key[65];
};

Config configuration{};
WebServer server(port);
String host;
char serialLine[274];
size_t serialLength = 0;
bool discardLine = false;
bool online = false;
bool dutyReady = false;
bool lit = false;
uint32_t lastCommand = 0;
uint32_t lastReconnect = 0;

int nibble(char ch) {
  if (ch >= '0' && ch <= '9') return ch - '0';
  if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
  return -1;
}

bool decode(const char *hex, char *output, size_t capacity) {
  size_t size = strlen(hex);
  if (size % 2 || size / 2 >= capacity) return false;
  for (size_t i = 0; i < size; i += 2) {
    int high = nibble(hex[i]), low = nibble(hex[i + 1]);
    if (high < 0 || low < 0 || (high == 0 && low == 0)) return false;
    output[i / 2] = char((high << 4) | low);
  }
  output[size / 2] = '\0';
  return true;
}

bool validKey(const char *key) {
  if (strlen(key) != 64) return false;
  for (int i = 0; i < 64; i++) {
    if (nibble(key[i]) < 0) return false;
  }
  return true;
}

void setLight(unsigned brightness) {
  if (dutyReady) ledcWrite(outputPin, (brightness * 255 + 50) / 100);
  lit = brightness != 0 && dutyReady;
}

void reconnect() {
  setLight(0);
  if (online) {
    server.stop();
    MDNS.end();
    online = false;
  }
  WiFi.disconnect();
  if (configuration.ssid[0]) WiFi.begin(configuration.ssid, configuration.password);
  lastReconnect = millis();
}

void stateRequest() {
  String key = server.header(keyHeader);
  if (key.length() != 64 || !configuration.key[0]) {
    server.send(401, "text/plain", "Pair with this sign first.");
    return;
  }
  unsigned mismatch = 0;
  for (int i = 0; i < 64; i++) mismatch |= key[i] ^ configuration.key[i];
  if (mismatch) {
    server.send(401, "text/plain", "Pair with this sign again.");
    return;
  }
  String value = server.arg("level");
  int level = 0;
  if (!value.length() || value.length() > 3) {
    server.send(400, "text/plain", "Expected level 0-100.");
    return;
  }
  for (char ch : value) {
    if (ch < '0' || ch > '9') {
      server.send(400, "text/plain", "Expected level 0-100.");
      return;
    }
    level = 10 * level + ch - '0';
  }
  if (level > 100 || !dutyReady) {
    server.send(level > 100 ? 400 : 503, "text/plain", "Invalid level or unavailable GPIO.");
    return;
  }
  lastCommand = millis();
  setLight(level);
  server.send(200, "application/json", String("{\"protocol\":1,\"level\":") + level + "}");
}

void serialCommand(char *line) {
  if (!strcmp(line, "ON-AIR-PING")) {
    String address = WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString() : "-";
    Serial.printf("ON-AIR-READY %s.local %s\n", host.c_str(), address.c_str());
    return;
  }
  constexpr char prefix[] = "ON-AIR-SET ";
  if (strncmp(line, prefix, sizeof(prefix) - 1)) return;
  char *ssid = line + sizeof(prefix) - 1;
  char *password = strchr(ssid, ' ');
  char *key = password ? strchr(password + 1, ' ') : nullptr;
  if (!key) {
    Serial.println("ON-AIR-ERROR Bad setup message");
    return;
  }
  *password++ = 0;
  *key++ = 0;
  Config next{};
  if (!decode(ssid, next.ssid, sizeof(next.ssid)) || !next.ssid[0] ||
      !decode(password, next.password, sizeof(next.password)) ||
      (next.password[0] && strlen(next.password) < 8) || !validKey(key)) {
    Serial.println("ON-AIR-ERROR Invalid Wi-Fi name, password or pairing key");
    return;
  }
  memcpy(next.key, key, sizeof(next.key));
  Preferences preferences;
  if (!preferences.begin("stepped-studio", false) ||
      preferences.putBytes("config", &next, sizeof(next)) != sizeof(next)) {
    Serial.println("ON-AIR-ERROR Could not save setup");
    return;
  }
  preferences.end();
  configuration = next;
  reconnect();
  Serial.printf("ON-AIR-SAVED %s.local\n", host.c_str());
}

void handleSerial() {
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == '\r') continue;
    if (ch == '\n') {
      if (!discardLine) {
        serialLine[serialLength] = 0;
        serialCommand(serialLine);
      }
      serialLength = 0;
      discardLine = false;
    } else if (serialLength < sizeof(serialLine) - 1) {
      serialLine[serialLength++] = ch;
    } else {
      discardLine = true;
    }
  }
}

void handleWiFi() {
  if (WiFi.status() == WL_CONNECTED) {
    if (!online) {
      MDNS.begin(host.c_str());
      server.begin();
      online = true;
      Serial.printf("ON-AIR-WIFI %s.local %s\n", host.c_str(), WiFi.localIP().toString().c_str());
    }
  } else {
    if (online) {
      setLight(0);
      server.stop();
      MDNS.end();
      online = false;
    }
    if (configuration.ssid[0] && millis() - lastReconnect > 30000) reconnect();
  }
}
} // namespace

void setup() {
  pinMode(outputPin, OUTPUT);
  digitalWrite(outputPin, LOW);
  dutyReady = ledcAttach(outputPin, 4000, 8);
  setLight(0);
  Serial.begin(115200);
  char name[24];
  snprintf(name, sizeof(name), "onair-%012llx", (unsigned long long)(ESP.getEfuseMac() & 0xffffffffffffULL));
  host = name;

  Preferences preferences;
  if (preferences.begin("stepped-studio", true)) {
    if (preferences.getBytesLength("config") == sizeof(configuration)) {
      preferences.getBytes("config", &configuration, sizeof(configuration));
    }
    preferences.end();
  }
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  WiFi.setHostname(host.c_str());

  const char *headers[] = {keyHeader};
  server.collectHeaders(headers, 1);
  server.on("/v1/state", HTTP_POST, stateRequest);
  server.onNotFound([] { server.send(404, "text/plain", "Stepped Studio ON AIR"); });
  reconnect();
}

void loop() {
  handleSerial();
  handleWiFi();
  if (lit && millis() - lastCommand >= leaseMs) setLight(0);
  if (online) server.handleClient();
  delay(5);
}
