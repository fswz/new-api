#!/usr/bin/env bash
set -euo pipefail

echo "audit_version=1"
echo "hostname=$(hostname)"
echo "architecture=$(uname -m)"
echo "kernel=$(uname -sr)"
echo "user=$(id -un)"
echo "uid=$(id -u)"
echo "groups=$(id -Gn)"

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  echo "os_id=${ID:-unknown}"
  echo "os_version=${VERSION_ID:-unknown}"
fi

echo "cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown)"
awk '/MemTotal:/ { print "memory_kib=" $2 }' /proc/meminfo
df -Pk / | awk 'NR == 2 { print "root_total_kib=" $2; print "root_available_kib=" $4 }'

for command_name in caddy nginx docker git go bun psql redis-server; do
  if command -v "$command_name" >/dev/null 2>&1; then
    echo "command_${command_name}=present"
  else
    echo "command_${command_name}=absent"
  fi
done

if sudo -n true >/dev/null 2>&1; then
  echo "passwordless_sudo=yes"
else
  echo "passwordless_sudo=no"
fi

if command -v systemctl >/dev/null 2>&1; then
  for unit_name in caddy nginx postgresql redis-server docker leyao-new-api; do
    state=$(systemctl is-active "$unit_name" 2>/dev/null || true)
    [[ -n "$state" ]] || state=unknown
    echo "service_${unit_name}=${state}"
  done
fi

if command -v ss >/dev/null 2>&1; then
  echo "listening_tcp_begin"
  ss -lntH | awk '{ print $4 }' | sort -u
  echo "listening_tcp_end"
fi

for path_name in /srv/leyao-new-api /etc/leyao-new-api /etc/caddy/Caddyfile; do
  if [[ -e "$path_name" ]]; then
    echo "path_${path_name}=present"
  else
    echo "path_${path_name}=absent"
  fi
done

if command -v apt-cache >/dev/null 2>&1; then
  for package_name in caddy postgresql redis-server; do
    candidate=$(apt-cache policy "$package_name" 2>/dev/null | awk '/Candidate:/ { print $2; exit }' || true)
    [[ -n "$candidate" ]] || candidate=none
    echo "apt_candidate_${package_name}=${candidate}"
  done
fi
