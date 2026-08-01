#!/usr/bin/env bash
set -euo pipefail

domain=${DOMAIN:-leyao.fswz.cc}

if [[ $(id -u) -ne 0 ]]; then
  exec sudo -n env DOMAIN="$domain" bash "$0"
fi

echo "verification_version=1"
echo "application_service=$(systemctl is-active leyao-new-api)"
echo "postgresql_service=$(systemctl is-active postgresql)"
echo "redis_service=$(systemctl is-active redis-server)"
echo "caddy_service=$(systemctl is-active caddy)"

echo "release_begin"
cat /srv/leyao-new-api/current/RELEASE
cat /srv/leyao-new-api/current/SHA256SUMS
echo "release_end"

echo "local_status_begin"
curl --fail --silent --show-error http://127.0.0.1:3000/api/status
echo
echo "local_status_end"

echo "https_headers_begin"
curl --fail --silent --show-error \
  --head \
  --max-time 30 \
  --resolve "${domain}:443:127.0.0.1" \
  "https://${domain}/"
echo "https_headers_end"

echo "https_status_begin"
curl --fail --silent --show-error \
  --max-time 30 \
  --resolve "${domain}:443:127.0.0.1" \
  "https://${domain}/api/status"
echo
echo "https_status_end"

echo "certificate_begin"
openssl x509 \
  -in /etc/caddy/certs/leyao.fullchain.pem \
  -noout \
  -subject \
  -issuer \
  -dates
echo "certbot_timer=$(systemctl is-active certbot.timer)"
echo "certificate_end"

echo "listeners_begin"
ss -lntH | awk '{ print $4 }' | sort -u
echo "listeners_end"

echo "ufw_begin"
sudo -n ufw status
echo "ufw_end"

echo "verification_status=complete"
