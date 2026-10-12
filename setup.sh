#!/bin/bash
# «Вдвоём» — свой сервер: посредник для подключения (MQTT по wss) + ретранслятор звонка (TURN).
# Запуск на чистом Ubuntu 22.04/24.04 от root:
#   curl -fsSL https://lmk464220-arch.github.io/vdvoem/setup.sh | bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "=== Вдвоём: настраиваю сервер ==="
IP=$(curl -4 -fsS https://api.ipify.org || curl -4 -fsS https://ifconfig.me || hostname -I | awk '{print $1}')
if [ -z "$IP" ]; then echo "Не удалось узнать IP сервера"; exit 1; fi
HOST="${IP//./-}.sslip.io"          # бесплатное имя, которое указывает на этот IP — нужно для https
PASS_FILE=/etc/vdvoem-turn-pass
if [ -f "$PASS_FILE" ]; then PASS=$(cat "$PASS_FILE"); else PASS=$(openssl rand -hex 8); echo "$PASS" > "$PASS_FILE"; chmod 600 "$PASS_FILE"; fi

echo "--- ставлю программы (пара минут) ---"
apt-get update -y
apt-get install -y mosquitto coturn curl
if ! apt-get install -y caddy; then
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y && apt-get install -y caddy
fi

echo "--- посредник (MQTT) ---"
cat > /etc/mosquitto/conf.d/vdvoem.conf <<EOF
listener 9001 127.0.0.1
protocol websockets
allow_anonymous true
persistent_client_expiration 2h
max_queued_messages 300
EOF
systemctl enable mosquitto >/dev/null 2>&1 || true
systemctl restart mosquitto

echo "--- https (сертификат выдаётся автоматически) ---"
cat > /etc/caddy/Caddyfile <<EOF
$HOST {
	@mqtt path /mqtt*
	reverse_proxy @mqtt 127.0.0.1:9001
	respond "Vdvoem server OK" 200
}
EOF
systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy

echo "--- ретранслятор звонка (TURN) ---"
cat > /etc/turnserver.conf <<EOF
listening-port=3478
fingerprint
lt-cred-mech
user=vdvoem:$PASS
realm=vdvoem
external-ip=$IP
min-port=49160
max-port=49999
no-cli
no-multicast-peers
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
EOF
[ -f /etc/default/coturn ] && sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn || true
systemctl enable coturn >/dev/null 2>&1 || true
systemctl restart coturn

if command -v ufw >/dev/null && ufw status | grep -q active; then
  ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 3478/tcp; ufw allow 3478/udp; ufw allow 49160:49999/udp
fi

sleep 5
echo
echo "=== Проверка ==="
for s in mosquitto caddy coturn; do printf "%-10s %s\n" "$s" "$(systemctl is-active $s)"; done
echo
echo "=============================================="
echo " ГОТОВО. Пришлите Claude эту строку целиком:"
echo
echo "   VDVOEM $HOST $IP $PASS"
echo
echo "=============================================="
