#!/usr/bin/env bash
# my-vacbox — установка ШЛЮЗА на Raspberry Pi 4 (Raspberry Pi OS / Debian).
# Весь трафик домашней сети уходит в туннель через sing-box (режим TUN),
# с защитой от утечек (kill-switch) и DNS внутри туннеля (DoH).
# Запускать от root.
#
# Переменные (необязательно):
#   PARAMS=/etc/my-vacbox/client-params.env  — файл с сервера
#   SB_VERSION=1.11.15                        — зафиксировать версию sing-box
set -euo pipefail

PARAMS="${PARAMS:-/etc/my-vacbox/client-params.env}"
CONF_DIR="/etc/sing-box"
CONF="$CONF_DIR/config.json"
TUN="singtun"
KS="/etc/my-vacbox/killswitch.nft"

log(){ echo "[my-vacbox] $*"; }
die(){ echo "[my-vacbox][ОШИБКА] $*" >&2; exit 1; }
need_root(){ [ "$(id -u)" -eq 0 ] || die "Запусти от root (sudo bash pi/install.sh)."; }

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
Description=sing-box (my-vacbox gateway)
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

write_config(){
  mkdir -p "$CONF_DIR"
  log "Пишу конфиг клиента-шлюза…"
  cat > "$CONF" <<JSON
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
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "$TUN",
      "address": [ "172.19.0.1/30" ],
      "mtu": 1420,
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "proxy",
      "outbounds": [ "vless", "hysteria2" ],
      "default": "vless"
    },
    {
      "type": "vless",
      "tag": "vless",
      "server": "$SERVER_ADDR",
      "server_port": $VLESS_PORT,
      "uuid": "$VLESS_UUID",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "$REALITY_PUBKEY",
          "short_id": "$REALITY_SHORTID"
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "server": "$SERVER_ADDR",
      "server_port": ${HY2_PORT:-8443},
      "password": "${HY2_PASSWORD:-changeme}",
      "tls": { "enabled": true, "insecure": true, "alpn": [ "h3" ] }
    },
    { "type": "direct", "tag": "direct" },
    { "type": "dns", "tag": "dns-out" }
  ],
  "route": {
    "rules": [
      { "protocol": "dns", "outbound": "dns-out" },
      { "ip_is_private": true, "outbound": "direct" }
    ],
    "final": "proxy",
    "auto_detect_interface": true
  }
}
JSON
  sing-box check -c "$CONF" || die "sing-box отверг конфиг (возможно, другая версия схемы) — пришли вывод, поправлю."
}

enable_forwarding(){
  log "Включаю IP-форвардинг…"
  cat > /etc/sysctl.d/99-my-vacbox.conf <<'SYS'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
SYS
  sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-my-vacbox.conf >/dev/null 2>&1 || true
}

write_killswitch(){
  log "Ставлю kill-switch (nftables)…"
  mkdir -p /etc/my-vacbox
  cat > "$KS" <<'NFT'
#!/usr/sbin/nft -f
# my-vacbox kill-switch: форвард-трафик домашних устройств выпускается ТОЛЬКО
# в туннель (singtun). Если sing-box упал — устройства теряют интернет,
# но НЕ утекают в открытую сеть мимо туннеля.
table inet myvacbox
delete table inet myvacbox
table inet myvacbox {
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname "singtun" accept
    oifname "singtun" accept
    # локальный трафик внутри дома (LAN<->LAN) разрешён
    ip saddr 192.168.0.0/16 ip daddr 192.168.0.0/16 accept
    ip saddr 10.0.0.0/8     ip daddr 10.0.0.0/8     accept
    ip saddr 172.16.0.0/12  ip daddr 172.16.0.0/12  accept
    counter comment "dropped-leak"
  }
}
NFT
  cat > /etc/systemd/system/my-vacbox-killswitch.service <<'UNIT'
[Unit]
Description=my-vacbox kill-switch (nftables)
After=sing-box.service
Wants=sing-box.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/my-vacbox/killswitch.nft
ExecStop=/usr/sbin/nft delete table inet myvacbox
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable my-vacbox-killswitch >/dev/null 2>&1 || true
  systemctl restart my-vacbox-killswitch || die "не применился kill-switch: nft -f $KS"
}

main(){
  need_root
  [ -f "$PARAMS" ] || die "нет файла параметров: $PARAMS
    Скопируй с сервера my-vacbox-client-params.env сюда:
      sudo mkdir -p /etc/my-vacbox
      sudo cp client-params.env /etc/my-vacbox/client-params.env"

  # shellcheck disable=SC1090
  . "$PARAMS"
  : "${SERVER_ADDR:?нет SERVER_ADDR в $PARAMS}"
  : "${VLESS_PORT:?}" "${VLESS_UUID:?}" "${REALITY_PUBKEY:?}" "${REALITY_SHORTID:?}" "${REALITY_SNI:?}"

  log "Ставлю зависимости…"
  apt-get update -y
  apt-get install -y nftables curl ca-certificates

  install_singbox
  write_config
  enable_forwarding
  write_killswitch

  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
  sleep 2
  systemctl is-active --quiet sing-box || die "sing-box не стартовал: journalctl -u sing-box -n50"

  local pi_ip; pi_ip="$(hostname -I | awk '{print $1}')"
  echo
  echo "============================================================"
  echo " ШЛЮЗ ПОДНЯТ. IP малины: $pi_ip"
  echo "------------------------------------------------------------"
  echo " Чтобы весь дом пошёл через туннель — в настройках ДОМАШНЕГО"
  echo " роутера (раздел DHCP/LAN) укажи:"
  echo "     Шлюз по умолчанию (Gateway) : $pi_ip"
  echo "     DNS-сервер                  : $pi_ip"
  echo " Либо вручную на нужном устройстве пропиши этот шлюз и DNS."
  echo "------------------------------------------------------------"
  echo " Проверка (с устройства за малиной):"
  echo "     curl https://api.ipify.org   → должен показать IP сервера (VPS)"
  echo " Логи:   journalctl -u sing-box -f"
  echo " Статус: systemctl status sing-box my-vacbox-killswitch"
  echo "============================================================"
}
main "$@"
