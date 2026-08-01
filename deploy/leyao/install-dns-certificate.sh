#!/usr/bin/env bash
set -euo pipefail

domain=${DOMAIN:-leyao.fswz.cc}
dns_zone=${DNS_ZONE:-fswz.cc}
access_key_id=${ALIBABA_CLOUD_ACCESS_KEY_ID:?ALIBABA_CLOUD_ACCESS_KEY_ID is required}
access_key_secret=${ALIBABA_CLOUD_ACCESS_KEY_SECRET:?ALIBABA_CLOUD_ACCESS_KEY_SECRET is required}

if [[ $(id -u) -ne 0 ]]; then
  exec sudo -n -E bash "$0"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y certbot

install -d -m 0755 /usr/local/libexec
install -d -m 0750 -o root -g caddy /etc/caddy/certs
install -d -m 0750 -o root -g leyao-api /etc/leyao-new-api

umask 0077
cat > /etc/leyao-new-api/alidns-certbot.env <<EOF
ALIBABA_CLOUD_ACCESS_KEY_ID=$access_key_id
ALIBABA_CLOUD_ACCESS_KEY_SECRET=$access_key_secret
LEYAO_DNS_ZONE=$dns_zone
EOF
chmod 0600 /etc/leyao-new-api/alidns-certbot.env

cat > /usr/local/libexec/leyao-alidns-certbot.py <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


ENDPOINT = "https://alidns.aliyuncs.com/"
API_VERSION = "2015-01-09"


def percent_encode(value: object) -> str:
    return urllib.parse.quote(str(value), safe="~")


def call_api(action: str, **action_parameters: object) -> dict[str, object]:
    parameters: dict[str, object] = {
        "AccessKeyId": os.environ["ALIBABA_CLOUD_ACCESS_KEY_ID"],
        "Action": action,
        "Format": "JSON",
        "SignatureMethod": "HMAC-SHA1",
        "SignatureNonce": str(uuid.uuid4()),
        "SignatureVersion": "1.0",
        "Timestamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "Version": API_VERSION,
        **action_parameters,
    }
    canonical_query = "&".join(
        f"{percent_encode(key)}={percent_encode(parameters[key])}" for key in sorted(parameters)
    )
    string_to_sign = f"GET&%2F&{percent_encode(canonical_query)}"
    signing_key = (os.environ["ALIBABA_CLOUD_ACCESS_KEY_SECRET"] + "&").encode()
    signature = base64.b64encode(
        hmac.new(signing_key, string_to_sign.encode(), hashlib.sha1).digest()
    ).decode()
    request_url = ENDPOINT + "?" + canonical_query + "&Signature=" + percent_encode(signature)

    try:
        with urllib.request.urlopen(request_url, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        try:
            payload = json.loads(exc.read().decode("utf-8", errors="replace"))
            code = payload.get("Code", "HTTPError")
            message = payload.get("Message", str(exc))
        except Exception:
            code = "HTTPError"
            message = str(exc)
        print(f"AliDNS error: {code}: {message}", file=sys.stderr)
        raise SystemExit(1) from exc


def record_rr(domain: str, zone: str) -> str:
    normalized_domain = domain.removeprefix("*.").rstrip(".")
    normalized_zone = zone.rstrip(".")
    if normalized_domain == normalized_zone:
        return "_acme-challenge"
    suffix = "." + normalized_zone
    if not normalized_domain.endswith(suffix):
        raise SystemExit(f"Domain {domain!r} is outside configured DNS zone {zone!r}")
    relative_name = normalized_domain[: -len(suffix)]
    return f"_acme-challenge.{relative_name}"


def authenticate() -> int:
    domain = os.environ["CERTBOT_DOMAIN"]
    validation = os.environ["CERTBOT_VALIDATION"]
    zone = os.environ["LEYAO_DNS_ZONE"]
    response = call_api(
        "AddDomainRecord",
        DomainName=zone,
        RR=record_rr(domain, zone),
        Type="TXT",
        Value=validation,
        TTL=600,
    )
    record_id = str(response.get("RecordId") or "")
    if not record_id.isdigit():
        raise SystemExit("AliDNS did not return a valid RecordId")
    time.sleep(35)
    print(record_id)
    return 0


def cleanup() -> int:
    record_id = os.environ.get("CERTBOT_AUTH_OUTPUT", "").strip()
    if record_id.isdigit():
        call_api("DeleteDomainRecord", RecordId=record_id)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in {"auth", "cleanup"}:
        raise SystemExit("Usage: leyao-alidns-certbot.py {auth|cleanup}")
    raise SystemExit(authenticate() if sys.argv[1] == "auth" else cleanup())
PY
chmod 0700 /usr/local/libexec/leyao-alidns-certbot.py

cat > /usr/local/libexec/leyao-certbot-auth <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
set -a
source /etc/leyao-new-api/alidns-certbot.env
set +a
exec /usr/local/libexec/leyao-alidns-certbot.py auth
EOF

cat > /usr/local/libexec/leyao-certbot-cleanup <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
set -a
source /etc/leyao-new-api/alidns-certbot.env
set +a
exec /usr/local/libexec/leyao-alidns-certbot.py cleanup
EOF

cat > /usr/local/libexec/leyao-certbot-deploy <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
install -m 0640 -o root -g caddy "$RENEWED_LINEAGE/fullchain.pem" /etc/caddy/certs/leyao.fullchain.pem
install -m 0640 -o root -g caddy "$RENEWED_LINEAGE/privkey.pem" /etc/caddy/certs/leyao.privkey.pem
if systemctl is-active caddy >/dev/null 2>&1; then
  systemctl reload caddy
fi
EOF

chmod 0700 \
  /usr/local/libexec/leyao-certbot-auth \
  /usr/local/libexec/leyao-certbot-cleanup \
  /usr/local/libexec/leyao-certbot-deploy

certbot certonly \
  --manual \
  --preferred-challenges dns \
  --manual-auth-hook /usr/local/libexec/leyao-certbot-auth \
  --manual-cleanup-hook /usr/local/libexec/leyao-certbot-cleanup \
  --deploy-hook /usr/local/libexec/leyao-certbot-deploy \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  --keep-until-expiring \
  --domain "$domain"

RENEWED_LINEAGE="/etc/letsencrypt/live/$domain" \
  /usr/local/libexec/leyao-certbot-deploy

cat > /etc/caddy/Caddyfile <<EOF
${domain} {
    tls /etc/caddy/certs/leyao.fullchain.pem /etc/caddy/certs/leyao.privkey.pem

    header {
        -Server
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    reverse_proxy 127.0.0.1:3000
}
EOF

caddy fmt --overwrite /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy
systemctl enable --now certbot.timer

curl --fail --silent --show-error \
  --head \
  --max-time 30 \
  --resolve "${domain}:443:127.0.0.1" \
  "https://${domain}/" >/dev/null

echo "certificate_status=installed"
echo "certificate_domain=$domain"
openssl x509 \
  -in /etc/caddy/certs/leyao.fullchain.pem \
  -noout \
  -subject \
  -issuer \
  -dates
