#!/usr/bin/env bash
set -euo pipefail

action=${1:-}
interface_name=${WG_INTERFACE:-wg-fswz}
config_path="/etc/wireguard/${interface_name}.conf"
private_key_path="/etc/wireguard/${interface_name}.key"
public_key_path="/etc/wireguard/${interface_name}.pub"

if [[ $(id -u) -ne 0 ]]; then
  exec sudo -n env \
    WG_INTERFACE="$interface_name" \
    CLIENT_ADDRESS="${CLIENT_ADDRESS:-}" \
    SERVER_PUBLIC_KEY="${SERVER_PUBLIC_KEY:-}" \
    ENDPOINT="${ENDPOINT:-}" \
    ALLOWED_IPS="${ALLOWED_IPS:-10.77.0.0/24}" \
    PEER_NAME="${PEER_NAME:-}" \
    PEER_PUBLIC_KEY="${PEER_PUBLIC_KEY:-}" \
    PEER_ALLOWED_IP="${PEER_ALLOWED_IP:-}" \
    PROXY_URL="${PROXY_URL:-http://10.77.0.2:7897}" \
    bash "$0" "$action"
fi

case "$action" in
  client-prepare)
    : "${CLIENT_ADDRESS:?CLIENT_ADDRESS is required}"
    : "${SERVER_PUBLIC_KEY:?SERVER_PUBLIC_KEY is required}"
    : "${ENDPOINT:?ENDPOINT is required}"
    allowed_ips=${ALLOWED_IPS:-10.77.0.0/24}

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard
    install -d -m 0700 /etc/wireguard

    if [[ ! -f "$private_key_path" ]]; then
      umask 0077
      wg genkey > "$private_key_path"
    fi
    wg pubkey < "$private_key_path" > "$public_key_path"
    chmod 0600 "$private_key_path" "$public_key_path"

    private_key=$(tr -d '\r\n' < "$private_key_path")
    client_public_key=$(tr -d '\r\n' < "$public_key_path")
    cat > "$config_path" <<EOF
[Interface]
PrivateKey = $private_key
Address = $CLIENT_ADDRESS
Table = off

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $ENDPOINT
AllowedIPs = $allowed_ips
PersistentKeepalive = 25
EOF
    chmod 0600 "$config_path"

    echo "wireguard_action=client-prepared"
    echo "wireguard_interface=$interface_name"
    echo "wireguard_address=$CLIENT_ADDRESS"
    echo "wireguard_allowed_ips=$allowed_ips"
    echo "client_public_key=$client_public_key"
    ;;

  hub-add-peer)
    : "${PEER_NAME:?PEER_NAME is required}"
    : "${PEER_PUBLIC_KEY:?PEER_PUBLIC_KEY is required}"
    : "${PEER_ALLOWED_IP:?PEER_ALLOWED_IP is required}"

    if [[ ! -f "$config_path" ]]; then
      echo "WireGuard Hub config not found: $config_path" >&2
      exit 1
    fi

    conflicting_key=$(
      wg show "$interface_name" allowed-ips \
        | awk -v target="$PEER_ALLOWED_IP" '$2 == target { print $1; exit }'
    )
    if [[ -n "$conflicting_key" && "$conflicting_key" != "$PEER_PUBLIC_KEY" ]]; then
      echo "Peer address is already assigned: $PEER_ALLOWED_IP" >&2
      exit 1
    fi

    temporary_config=$(mktemp)
    trap 'rm -f "$temporary_config"' EXIT
    awk \
      -v start="# BEGIN MANAGED PEER $PEER_NAME" \
      -v end="# END MANAGED PEER $PEER_NAME" \
      '$0 == start { skip=1; next } $0 == end { skip=0; next } !skip { print }' \
      "$config_path" > "$temporary_config"
    cat >> "$temporary_config" <<EOF

# BEGIN MANAGED PEER $PEER_NAME
[Peer]
PublicKey = $PEER_PUBLIC_KEY
AllowedIPs = $PEER_ALLOWED_IP
# END MANAGED PEER $PEER_NAME
EOF
    install -m 0600 "$temporary_config" "$config_path"
    wg syncconf "$interface_name" <(wg-quick strip "$interface_name")

    echo "wireguard_action=hub-peer-added"
    echo "wireguard_interface=$interface_name"
    echo "peer_name=$PEER_NAME"
    echo "peer_allowed_ip=$PEER_ALLOWED_IP"
    ;;

  client-activate)
    proxy_url=${PROXY_URL:-http://10.77.0.2:7897}
    systemctl enable --now "wg-quick@${interface_name}"
    systemctl restart "wg-quick@${interface_name}"

    for attempt in $(seq 1 15); do
      if ping -c 1 -W 2 10.77.0.1 >/dev/null 2>&1; then
        break
      fi
      if [[ "$attempt" -eq 15 ]]; then
        wg show "$interface_name" >&2
        ip route show >&2
        echo "WireGuard Hub did not become reachable" >&2
        exit 1
      fi
      sleep 2
    done

    proxy_status=$(curl \
      --silent \
      --show-error \
      --output /dev/null \
      --write-out '%{http_code}' \
      --max-time 30 \
      --proxy "$proxy_url" \
      https://github.com/)

    echo "wireguard_action=client-activated"
    echo "wireguard_interface=$interface_name"
    echo "hub_ping=ok"
    echo "github_via_proxy_status=$proxy_status"
    echo "public_route=$(ip route get 1.1.1.1 | head -n 1)"
    echo "private_route=$(ip route get 10.77.0.1 | head -n 1)"
    ;;

  *)
    echo "Usage: $0 {client-prepare|hub-add-peer|client-activate}" >&2
    exit 2
    ;;
esac
