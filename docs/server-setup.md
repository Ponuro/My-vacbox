# Настройка сервера (VPS)

## 1. Залить проект на сервер

```bash
# по SSH на VPS, под root:
apt-get update -y && apt-get install -y git
git clone <URL-этого-репозитория> my-vacbox
cd my-vacbox
```

(или просто скопируй файл `server/install.sh` через `scp`.)

## 2. Запустить установку

```bash
sudo bash server/install.sh
```

Скрипт:
- поставит `sing-box` (фиксированной версии 1.11.x),
- сгенерит UUID, ключи Reality, пароль Hysteria2,
- поднимет два канала: **VLESS+Reality** (TCP 443) и **Hysteria2** (UDP 8443),
- запустит сервис и откроет порты (если стоит `ufw`),
- сохранит параметры клиента в `/root/my-vacbox-client-params.env`.

### Полезные переменные

```bash
# другой маскировочный сайт и порты:
SNI=www.cloudflare.com VLESS_PORT=443 HY2_PORT=8443 sudo bash server/install.sh

# перегенерировать всё заново (новые ключи):
FORCE=1 sudo bash server/install.sh
```

**Про SNI:** это чужой реальный сайт, под который маскируется трафик. Хорошие
кандидаты — крупные сайты на TLS 1.3, быстрые с твоего VPS и не заблокированные
в РФ: `www.microsoft.com`, `www.cloudflare.com`, `dl.google.com`. Выбирай тот,
что быстрее пингуется с сервера.

## 3. Забрать параметры для малины

```bash
cat /root/my-vacbox-client-params.env
```

Этот файл нужно перенести на Raspberry Pi (`scp`, флешка, или просто скопировать
содержимое). Он содержит только **публичные** параметры клиента (приватный ключ
Reality остаётся на сервере) — но всё равно храни аккуратно.

## 4. Проверка

```bash
systemctl status sing-box
journalctl -u sing-box -n 50
```

## (Опционально) Hysteria2 с реальным доменом

По умолчанию резервный канал Hysteria2 использует self-signed сертификат, а
клиент ходит с `insecure: true`. Это нормально для обхода цензуры (данные и так
идут на твой же сервер), но «чище» — повесить реальный домен:

1. Направь A-запись домена на IP сервера.
2. Получи сертификат (`certbot` / встроенный ACME sing-box).
3. В `/etc/sing-box/config.json` в блоке `hy2-in.tls` укажи реальные
   `certificate_path`/`key_path`, а на малине убери `insecure: true` и поставь
   `server_name` = твой домен.

Следующий шаг → [pi-gateway.md](pi-gateway.md).
