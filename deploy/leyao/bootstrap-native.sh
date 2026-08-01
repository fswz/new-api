#!/usr/bin/env bash
set -euo pipefail

APP_NAME=leyao-new-api
APP_USER=leyao-api
APP_GROUP=leyao-api
APP_ROOT=/srv/leyao-new-api
APP_STATE=/var/lib/leyao-new-api
APP_LOG=/var/log/leyao-new-api
APP_CONFIG=/etc/leyao-new-api
APP_ENV="$APP_CONFIG/new-api.env"
DOMAIN=${DOMAIN:-leyao.fswz.cc}
REPOSITORY_URL=${REPOSITORY_URL:-https://github.com/fswz/new-api.git}
SOURCE_BRANCH=${SOURCE_BRANCH:-main}
RELEASE_REF=${RELEASE_REF:?RELEASE_REF must be an exact Git commit}
GO_VERSION=${GO_VERSION:-1.26.1}
GO_ARCHIVE_SHA256=${GO_ARCHIVE_SHA256:-031f088e5d955bab8657ede27ad4e3bc5b7c1ba281f05f245bcc304f327c987a}
BUN_VERSION=${BUN_VERSION:-1.3.14}
BUILD_PROXY_URL=${BUILD_PROXY_URL:-}

if [[ $(id -u) -ne 0 ]]; then
  exec sudo -n env \
    DOMAIN="$DOMAIN" \
    REPOSITORY_URL="$REPOSITORY_URL" \
    SOURCE_BRANCH="$SOURCE_BRANCH" \
    RELEASE_REF="$RELEASE_REF" \
    GO_VERSION="$GO_VERSION" \
    GO_ARCHIVE_SHA256="$GO_ARCHIVE_SHA256" \
    BUN_VERSION="$BUN_VERSION" \
    BUILD_PROXY_URL="$BUILD_PROXY_URL" \
    bash "$0"
fi

if [[ ! "$RELEASE_REF" =~ ^[0-9a-f]{40}$ ]]; then
  echo "RELEASE_REF must be a full 40-character lowercase Git commit" >&2
  exit 2
fi

if [[ $(uname -m) != x86_64 ]]; then
  echo "This deployment script currently supports x86_64 only" >&2
  exit 2
fi

if [[ -n "$BUILD_PROXY_URL" ]]; then
  export HTTP_PROXY="$BUILD_PROXY_URL"
  export HTTPS_PROXY="$BUILD_PROXY_URL"
  export http_proxy="$BUILD_PROXY_URL"
  export https_proxy="$BUILD_PROXY_URL"
  export ALL_PROXY="$BUILD_PROXY_URL"
  export all_proxy="$BUILD_PROXY_URL"
  export NO_PROXY="localhost,127.0.0.1,::1,10.77.0.0/24,mirrors.tencentyun.com,$DOMAIN"
  export no_proxy="$NO_PROXY"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  ca-certificates \
  caddy \
  curl \
  git \
  postgresql \
  redis-server \
  ufw \
  unzip

if [[ -x /usr/local/go/bin/go ]]; then
  installed_go_version=$(/usr/local/go/bin/go version | awk '{ print $3 }')
  if [[ "$installed_go_version" != "go${GO_VERSION}" ]]; then
    echo "Unexpected Go version at /usr/local/go: $installed_go_version" >&2
    exit 1
  fi
else
  go_archive=$(mktemp)
  trap 'rm -f "$go_archive"' EXIT
  curl --fail --location --silent --show-error \
    "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
    --output "$go_archive"
  echo "$GO_ARCHIVE_SHA256  $go_archive" | sha256sum --check --status
  tar -C /usr/local -xzf "$go_archive"
  rm -f "$go_archive"
  trap - EXIT
fi
ln -sfn /usr/local/go/bin/go /usr/local/bin/go
ln -sfn /usr/local/go/bin/gofmt /usr/local/bin/gofmt

if [[ -x /usr/local/lib/bun/bun ]]; then
  installed_bun_version=$(/usr/local/lib/bun/bun --version)
  if [[ "$installed_bun_version" != "$BUN_VERSION" ]]; then
    echo "Unexpected Bun version at /usr/local/lib/bun/bun: $installed_bun_version" >&2
    exit 1
  fi
else
  bun_workdir=$(mktemp -d)
  trap 'rm -rf "$bun_workdir"' EXIT
  curl --fail --location --silent --show-error \
    "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64.zip" \
    --output "$bun_workdir/bun-linux-x64.zip"
  curl --fail --location --silent --show-error \
    "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/SHASUMS256.txt" \
    --output "$bun_workdir/SHASUMS256.txt"
  expected_bun_sha=$(awk '$2 == "bun-linux-x64.zip" { print $1; exit }' "$bun_workdir/SHASUMS256.txt")
  if [[ -z "$expected_bun_sha" ]]; then
    echo "Bun checksum entry not found" >&2
    exit 1
  fi
  echo "$expected_bun_sha  $bun_workdir/bun-linux-x64.zip" | sha256sum --check --status
  unzip -q "$bun_workdir/bun-linux-x64.zip" -d "$bun_workdir"
  install -d -m 0755 /usr/local/lib/bun
  install -m 0755 "$bun_workdir/bun-linux-x64/bun" /usr/local/lib/bun/bun
  rm -rf "$bun_workdir"
  trap - EXIT
fi
ln -sfn /usr/local/lib/bun/bun /usr/local/bin/bun

if ! getent group "$APP_GROUP" >/dev/null; then
  groupadd --system "$APP_GROUP"
fi
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd \
    --system \
    --gid "$APP_GROUP" \
    --home-dir "$APP_STATE" \
    --shell /usr/sbin/nologin \
    "$APP_USER"
fi

install -d -m 0755 -o root -g root "$APP_ROOT" "$APP_ROOT/releases" "$APP_ROOT/builds"
install -d -m 0750 -o "$APP_USER" -g "$APP_GROUP" "$APP_STATE" "$APP_LOG"
install -d -m 0750 -o root -g "$APP_GROUP" "$APP_CONFIG"

systemctl enable --now postgresql

if [[ ! -f "$APP_ENV" ]]; then
  db_password=$(openssl rand -hex 32)
  redis_password=$(openssl rand -hex 32)
  session_secret=$(openssl rand -hex 48)
  crypto_secret=$(openssl rand -hex 48)

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'leyao_new_api'" | grep -qx 1; then
    sudo -u postgres psql --set ON_ERROR_STOP=1 \
      --command "CREATE ROLE leyao_new_api LOGIN PASSWORD '$db_password';"
  else
    sudo -u postgres psql --set ON_ERROR_STOP=1 \
      --command "ALTER ROLE leyao_new_api PASSWORD '$db_password';"
  fi
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = 'leyao_new_api'" | grep -qx 1; then
    sudo -u postgres createdb --owner=leyao_new_api leyao_new_api
  fi

  install -m 0640 -o redis -g redis /etc/redis/redis.conf /etc/redis/leyao-new-api.conf
  {
    echo
    echo "# Managed by $APP_NAME"
    echo "bind 127.0.0.1 -::1"
    echo "protected-mode yes"
    echo "requirepass $redis_password"
  } >> /etc/redis/leyao-new-api.conf

  install -d -m 0755 /etc/systemd/system/redis-server.service.d
  cat > /etc/systemd/system/redis-server.service.d/leyao-new-api.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/redis-server /etc/redis/leyao-new-api.conf --supervised systemd --daemonize no
EOF

  umask 0027
  cat > "$APP_ENV" <<EOF
PORT=3000
GIN_MODE=release
TZ=Asia/Shanghai
SQL_DSN=postgresql://leyao_new_api:${db_password}@127.0.0.1:5432/leyao_new_api?sslmode=disable
REDIS_CONN_STRING=redis://:${redis_password}@127.0.0.1:6379/0
SESSION_SECRET=${session_secret}
CRYPTO_SECRET=${crypto_secret}
SESSION_COOKIE_SECURE=true
SESSION_COOKIE_TRUSTED_URL=https://${DOMAIN}
TRUSTED_PROXIES=127.0.0.1/32,::1/128
ERROR_LOG_ENABLED=true
BATCH_UPDATE_ENABLED=true
NODE_NAME=leyao-prod-1
EOF
  chown root:"$APP_GROUP" "$APP_ENV"
  chmod 0640 "$APP_ENV"
else
  echo "Existing application environment preserved"
fi

systemctl daemon-reload
systemctl enable redis-server
systemctl restart redis-server

short_ref=${RELEASE_REF:0:12}
release_id=$(date -u +%Y%m%dT%H%M%SZ)-$short_ref
build_root="$APP_ROOT/builds/$release_id"
release_root="$APP_ROOT/releases/$release_id"

if [[ -e "$build_root" || -e "$release_root" ]]; then
  echo "Release path already exists: $release_id" >&2
  exit 1
fi

install -d -m 0755 -o root -g root "$build_root" "$release_root"
git -c advice.detachedHead=false clone \
  --depth 1 \
  --branch "$SOURCE_BRANCH" \
  "$REPOSITORY_URL" \
  "$build_root/source"

actual_ref=$(git -C "$build_root/source" rev-parse HEAD)
if [[ "$actual_ref" != "$RELEASE_REF" ]]; then
  echo "Source verification failed: expected $RELEASE_REF, got $actual_ref" >&2
  exit 1
fi

release_version="fswz-${short_ref}"
pushd "$build_root/source/web" >/dev/null
bun install --frozen-lockfile
DISABLE_ESLINT_PLUGIN=true VITE_REACT_APP_VERSION="$release_version" bun run build
popd >/dev/null

pushd "$build_root/source" >/dev/null
GOWORK=off CGO_ENABLED=0 go mod download
GOWORK=off CGO_ENABLED=0 go build \
  -trimpath \
  -ldflags "-s -w -X 'github.com/QuantumNous/new-api/common.Version=$release_version'" \
  -o "$release_root/new-api" \
  .
popd >/dev/null

chmod 0755 "$release_root/new-api"
sha256sum "$release_root/new-api" > "$release_root/SHA256SUMS"
cat > "$release_root/RELEASE" <<EOF
repository=$REPOSITORY_URL
commit=$RELEASE_REF
version=$release_version
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
go_version=$(go version)
bun_version=$(bun --version)
EOF

cat > /etc/systemd/system/leyao-new-api.service <<EOF
[Unit]
Description=New API for leyao.fswz.cc
Wants=network-online.target
After=network-online.target postgresql.service redis-server.service
Requires=postgresql.service redis-server.service

[Service]
Type=simple
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$APP_STATE
EnvironmentFile=$APP_ENV
ExecStart=$APP_ROOT/current/new-api --log-dir $APP_LOG
Restart=always
RestartSec=5s
TimeoutStopSec=150s
LimitNOFILE=1048576
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
ReadWritePaths=$APP_STATE $APP_LOG

[Install]
WantedBy=multi-user.target
EOF

if [[ -f /etc/caddy/Caddyfile ]]; then
  cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.pre-leyao.$(date +%Y%m%d-%H%M%S)"
fi

caddy_tls_directive=""
if [[ -f /etc/caddy/certs/leyao.fullchain.pem && -f /etc/caddy/certs/leyao.privkey.pem ]]; then
  caddy_tls_directive="    tls /etc/caddy/certs/leyao.fullchain.pem /etc/caddy/certs/leyao.privkey.pem"
fi

cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
${caddy_tls_directive}

    header {
        -Server
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    reverse_proxy 127.0.0.1:3000
}
EOF

caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

previous_release=$(readlink -f "$APP_ROOT/current" 2>/dev/null || true)
if [[ -n "$previous_release" ]]; then
  install -d -m 0700 -o root -g root "$APP_ROOT/backups"
  set -a
  source "$APP_ENV"
  set +a
  pg_dump "$SQL_DSN" \
    --format=custom \
    --file="$APP_ROOT/backups/pre-${release_id}.dump"
  chmod 0600 "$APP_ROOT/backups/pre-${release_id}.dump"
fi

next_link="$APP_ROOT/.current-$release_id"
ln -s "$release_root" "$next_link"
mv -Tf "$next_link" "$APP_ROOT/current"

systemctl daemon-reload
systemctl enable leyao-new-api
systemctl restart leyao-new-api

for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error http://127.0.0.1:3000/api/status >/dev/null; then
    break
  fi
  if [[ "$attempt" -eq 30 ]]; then
    journalctl -u leyao-new-api --no-pager -n 80 >&2
    exit 1
  fi
  sleep 2
done

systemctl enable --now caddy
systemctl reload caddy

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
# Preserve the pre-existing Palworld service hosted on this machine.
ufw allow 8211/udp
ufw allow 27015/udp
ufw --force enable

echo "deployment_status=complete"
echo "release_id=$release_id"
echo "release_commit=$RELEASE_REF"
echo "release_version=$release_version"
echo "previous_release=${previous_release:-none}"
echo "binary_sha256=$(sha256sum "$release_root/new-api" | awk '{ print $1 }')"
echo "application_service=$(systemctl is-active leyao-new-api)"
echo "postgresql_service=$(systemctl is-active postgresql)"
echo "redis_service=$(systemctl is-active redis-server)"
echo "caddy_service=$(systemctl is-active caddy)"
echo "ufw_status=$(ufw status | awk 'NR == 1 { print $2 }')"
