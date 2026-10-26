#!/usr/bin/env bash
# my-vacbox — самопроверка Raspberry Pi ПЕРЕД установкой.
# НИЧЕГО не меняет в системе: только проверяет готовность и валидирует конфиг
# командой `sing-box check` под реально установленную/скачанную версию.
# Можно запускать без root. В конце печатает отчёт — скинь его целиком.
#
# Переменные (необязательно):
#   PARAMS=/etc/my-vacbox/client-params.env  — если уже есть файл с сервера,
#                                               проверка пойдёт на реальных данных
set -uo pipefail

PARAMS="${PARAMS:-/etc/my-vacbox/client-params.env}"
TUN="singtun"
OK="[ OK ]"; FAIL="[FAIL]"; WARN="[WARN]"
RESULT=0
note(){ echo "$*"; }

echo "================= my-vacbox preflight ================="

# --- система ---
note "ОС:        $( (. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}") )"
note "Ядро:      $(uname -r)"
RAW_ARCH="$(uname -m)"
case "$RAW_ARCH" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l|armv7)  ARCH=armv7 ;;
  *) ARCH="" ;;
esac
if [ -n "$ARCH" ]; then note "$OK Архитектура: $RAW_ARCH → sing-box $ARCH"; else note "$FAIL Неизвестная архитектура: $RAW_ARCH"; RESULT=1; fi
if [ "$ARCH" = "armv7" ]; then note "$WARN 32-bit ОС. Будет работать, но на Pi 4 лучше 64-bit (arm64) ради скорости шифрования."; fi

# --- TUN ---
if [ -c /dev/net/tun ]; then note "$OK Поддержка TUN: /dev/net/tun есть"; else note "$FAIL Нет /dev/net/tun — туннель не поднимется (нужен модуль tun)"; RESULT=1; fi

# --- nftables ---
if command -v nft >/dev/null 2>&1; then note "$OK nftables: $(nft --version 2>/dev/null)"; else note "$WARN nftables не установлен — install.sh поставит сам (apt install nftables)"; fi

# --- ip_forward ---
IPF="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')"
note "ip_forward сейчас: $IPF (install.sh включит в 1)"

# --- sing-box: берём установленный, иначе качаем во ВРЕМЕННУЮ папку только для проверки ---
SB=""
if command -v sing-box >/dev/null 2>&1; then
  SB="$(command -v sing-box)"
  note "$OK sing-box уже установлен: $("$SB" version 2>/dev/null | head -n1)"
elif [ -n "$ARCH" ]; then
  note "sing-box не установлен — качаю во временную папку только для проверки конфига…"
  ver="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases 2>/dev/null \
          | grep -oE '"tag_name": *"v1\.11\.[0-9]+"' | head -n1 | grep -oE '1\.11\.[0-9]+' || true)"
  [ -n "$ver" ] || ver="1.11.15"
  tmp="$(mktemp -d)"
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${ARCH}.tar.gz"
  if curl -fsSL "$url" -o "$tmp/sb.tgz" 2>/dev/null && [ -s "$tmp/sb.tgz" ]; then
    tar -xzf "$tmp/sb.tgz" -C "$tmp" 2>/dev/null
    SB="$tmp/sing-box-${ver}-linux-${ARCH}/sing-box"
    chmod +x "$SB" 2>/dev/null || true
    note "$OK Скачан sing-box v${ver} для проверки (в систему НЕ ставится)"
  else
    note "$WARN Не удалось скачать sing-box (нет сети/недоступен GitHub) — пропускаю проверку конфига"
  fi
fi

# --- рендер клиентского конфига и его проверка ---
if [ -n "$SB" ] && [ -x "$SB" ]; then
  if [ -f "$PARAMS" ]; then
    # shellcheck disable=SC1090
    . "$PARAMS"; note "$OK Нашёл параметры сервера: $PARAMS (проверяю на реальных данных)"
  else
    note "$WARN Нет $PARAMS — проверяю с ЗАГЛУШКАМИ (схему это проверит, рабочий конфиг — после установки сервера)"
    SERVER_ADDR="203.0.113.10"; VLESS_PORT="443"
    VLESS_UUID="11111111-1111-1111-1111-111111111111"
    REALITY_PUBKEY="placeholderPublicKeyplaceholderPublicKey0000"
    REALITY_SHORTID="aabbccdd"; REALITY_SNI="www.microsoft.com"
    HY2_PORT="8443"; HY2_PASSWORD="placeholder"
  fi

  tmpc="$(mktemp -d)"; cfg="$tmpc/config.json"
  cat > "$cfg" <<JSON
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "dns-remote", "address": "https://1.1.1.1/dns-query", "detour": "proxy" },
      { "tag": "dns-direct", "address": "https://77.88.8.8/dns-query", "detour": "direct" }
    ],
    "final": "dns-remote",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    { "type": "tun", "tag": "tun-in", "interface_name": "$TUN", "address": [ "172.19.0.1/30" ],
      "mtu": 1420, "auto_route": true, "strict_route": true, "stack": "system", "sniff": true }
  ],
  "outbounds": [
    { "type": "selector", "tag": "proxy", "outbounds": [ "vless", "hysteria2" ], "default": "vless" },
    { "type": "vless", "tag": "vless", "server": "$SERVER_ADDR", "server_port": $VLESS_PORT,
      "uuid": "$VLESS_UUID", "flow": "xtls-rprx-vision",
      "tls": { "enabled": true, "server_name": "$REALITY_SNI",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "$REALITY_PUBKEY", "short_id": "$REALITY_SHORTID" } } },
    { "type": "hysteria2", "tag": "hysteria2", "server": "$SERVER_ADDR", "server_port": ${HY2_PORT:-8443},
      "password": "${HY2_PASSWORD:-changeme}", "tls": { "enabled": true, "insecure": true, "alpn": [ "h3" ] } },
    { "type": "direct", "tag": "direct" },
    { "type": "dns", "tag": "dns-out" }
  ],
  "route": {
    "rules": [ { "protocol": "dns", "outbound": "dns-out" }, { "ip_is_private": true, "outbound": "direct" } ],
    "final": "proxy",
    "auto_detect_interface": true
  }
}
JSON
  note "----- sing-box check (клиентский конфиг) -----"
  if "$SB" check -c "$cfg"; then
    note "$OK Конфиг валиден для этой версии sing-box"
  else
    note "$FAIL Конфиг не прошёл проверку — СКИНЬ МНЕ ВЫВОД ВЫШЕ, поправлю схему под твою версию"
    RESULT=1
  fi
  rm -rf "$tmpc"
fi

echo "================= итог ================="
if [ "$RESULT" -eq 0 ]; then
  echo "$OK Малина готова. Можно ставить: sudo bash pi/install.sh"
else
  echo "$FAIL Есть проблемы выше — скинь весь вывод, разберёмся."
fi
echo "========================================"
exit 0
