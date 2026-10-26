#!/usr/bin/env bash
# my-vacbox — установка СЕРВЕРА на VPS за границей.
# Поднимает sing-box: VLESS+Reality (основной канал) + Hysteria2 (резерв).
# Протестировано под Ubuntu 22.04/24.04 и Debian 12. Запускать от root.
#
# Переменные (необязательно):
#   SNI=www.microsoft.com   — "маскировочный" сайт для Reality
#   VLESS_PORT=443          — порт основного канала (TCP)
#   HY2_PORT=8443           — порт резервного канала (UDP)
#   SB_VERSION=1.11.15      — зафиксировать версию sing-box
#   FORCE=1                 — перегенерировать конфиг/ключи заново
set -euo pipefail

SNI="${SNI:-www.microsoft.com}"
VLESS_PORT="${VLESS_PORT:-443}"
HY2_PORT="${HY2_PORT:-8443}"
CONF_DIR="/etc/sing-box"
CONF="$CONF_DIR/config.json"
PARAMS_OUT="/root/my-vacbox-client-params.env"
FORCE="${FORCE:-0}"

log(){ echo "[my-vacbox] $*"; }
die(){ echo "[my-vacbox][ОШИБКА] $*" >&2; exit 1; }
need_root(){ [ "$(id -u)" -eq 0 ] || die "Запусти от root (sudo bash server/install.sh)."; }

install_singbox(){
  if command -v sing-box >/dev/null 2>&1; then
    log "sing-box уже установлен: $(sing-box version 2>/dev/null | head -n1)"
    return
  fi
  local arch ver url tmp
  case "$(uname -m)" in
    x86_64|amd64)   arch=amd64 ;;
    aarch64|arm64)  arch=arm64 ;;
    armv7l|armv7)   arch=armv7 ;;
    *) die "Неизвестная архитектура: $(uname -m)" ;;
  esac
  ver="${SB_VERSION:-}"
  if [ -z "$ver" ]; then
    ver="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases 2>/dev/null \
            | grep -oE '"tag_name": *"v1\.11\.[0-9]+"' | head -n1 \
            | grep -oE '1\.11\.[0-9]+' || true)"
  fi
  [ -n "$ver" ] || ver="1.11.15"
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
  log "Качаю sing-box v${ver} (${arch})…"
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/sb.tgz" || die "не скачался sing-box ($url)"
  tar -xzf "$tmp/sb.tgz" -C "$tmp"
  install -m 0755 "$tmp/sing-box-${ver}-linux-${arch}/sing-box" /usr/local/bin/sing-box
  rm -rf "$tmp"
  cat > /etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box (my-vacbox)
After=network.target nss-lookup.target
[Service]
ExecStart=/usr/local/bin/sing-box run -C /etc/sing-box
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  log "sing-box установлен: $(/usr/local/bin/sing-box version | head -n1)"
}

detect_ip(){
  local ip
  ip="$(curl -fsSL -4 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(curl -fsSL -4 https://ifconfig.me 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "$ip"
}

gen_hy2_cert(){
  # self-signed сертификат для Hysteria2 (клиент ходит с insecure=true).
  # Для продакшена лучше реальный домен + Let's Encrypt — см. docs/server-setup.md.
  [ -f "$CONF_DIR/hy2.cert.pem" ] && return
  log "Генерирую self-signed сертификат для Hysteria2…"
  openssl ecparam -genkey -name prime256v1 -out "$CONF_DIR/hy2.key.pem" >/dev/null 2>&1
  openssl req -new -x509 -days 3650 -key "$CONF_DIR/hy2.key.pem" \
    -out "$CONF_DIR/hy2.cert.pem" -subj "/CN=$SNI" >/dev/null 2>&1
  chmod 600 "$CONF_DIR/hy2.key.pem"
}

main(){
  need_root
  command -v curl >/dev/null 2>&1 || { apt-get update -y && apt-get install -y curl; }
  command -v openssl >/dev/null 2>&1 || { apt-get update -y && apt-get install -y openssl; }
  install_singbox
  mkdir -p "$CONF_DIR"

  if [ -f "$CONF" ] && [ "$FORCE" != "1" ]; then
    log "Конфиг уже существует ($CONF). Для перегенерации: FORCE=1 sudo bash server/install.sh"
    [ -f "$PARAMS_OUT" ] && { echo; cat "$PARAMS_OUT"; }
    exit 0
  fi

  log "Генерирую секреты…"
  local UUID RKP RK_PRIV RK_PUB SHORT_ID HY2_PASS SERVER_IP
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  RKP="$(sing-box generate reality-keypair)"
  RK_PRIV="$(echo "$RKP" | awk '/PrivateKey/{print $2}')"
  RK_PUB="$(echo "$RKP"  | awk '/PublicKey/{print $2}')"
  [ -n "$RK_PRIV" ] && [ -n "$RK_PUB" ] || die "не удалось сгенерировать reality-keypair"
  SHORT_ID="$(openssl rand -hex 8)"
  HY2_PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-24)"
  SERVER_IP="$(detect_ip)"
  [ -n "$SERVER_IP" ] || die "не определился внешний IP — впиши вручную в $PARAMS_OUT"

  gen_hy2_cert

  log "Пишу конфиг сервера…"
  cat > "$CONF" <<JSON
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $VLESS_PORT,
      "users": [ { "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$SNI", "server_port": 443 },
          "private_key": "$RK_PRIV",
          "short_id": [ "$SHORT_ID" ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [ { "password": "$HY2_PASS" } ],
      "tls": {
        "enabled": true,
        "alpn": [ "h3" ],
        "certificate_path": "$CONF_DIR/hy2.cert.pem",
        "key_path": "$CONF_DIR/hy2.key.pem"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
JSON

  sing-box check -c "$CONF" || die "sing-box отверг конфиг (возможно, другая версия схемы) — пришли вывод, поправлю."

  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
  sleep 1
  systemctl is-active --quiet sing-box || die "sing-box не стартовал: journalctl -u sing-box -n50"

  # firewall (если используется ufw)
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$VLESS_PORT"/tcp >/dev/null 2>&1 || true
    ufw allow "$HY2_PORT"/udp  >/dev/null 2>&1 || true
  fi

  cat > "$PARAMS_OUT" <<ENV
# my-vacbox — параметры клиента. Скопируй этот файл на Raspberry Pi:
#   /etc/my-vacbox/client-params.env
SERVER_ADDR=$SERVER_IP
VLESS_PORT=$VLESS_PORT
VLESS_UUID=$UUID
REALITY_PUBKEY=$RK_PUB
REALITY_SHORTID=$SHORT_ID
REALITY_SNI=$SNI
HY2_PORT=$HY2_PORT
HY2_PASSWORD=$HY2_PASS
ENV
  chmod 600 "$PARAMS_OUT"

  echo
  echo "============================================================"
  echo " СЕРВЕР ГОТОВ. Параметры для малины сохранены в:"
  echo "   $PARAMS_OUT"
  echo " Перенеси этот файл на Raspberry Pi (scp/флешка) и запусти там pi/install.sh."
  echo "------------------------------------------------------------"
  cat "$PARAMS_OUT"
  echo "============================================================"
  echo " ВАЖНО: если у VPS-провайдера есть внешний firewall (панель),"
  echo " открой там порты: TCP $VLESS_PORT и UDP $HY2_PORT."
}
main "$@"
