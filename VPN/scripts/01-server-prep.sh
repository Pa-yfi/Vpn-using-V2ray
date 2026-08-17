#!/usr/bin/env bash
# 01-server-prep.sh — base packages, BBR, kernel check
# Ubuntu 22.04 / Debian 11+, run as root.
set -euo pipefail

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELL=$'\033[0;33m'; NC=$'\033[0m'
info() { printf '%s[*]%s %s\n' "$YELL" "$NC" "$1"; }
ok()   { printf '%s[✓]%s %s\n' "$GREEN" "$NC" "$1"; }
fail() { printf '%s[✗]%s %s\n' "$RED" "$NC" "$1"; }

[[ $EUID -eq 0 ]] || { fail "Run as root."; exit 1; }

info "Disabling interactive needrestart prompts"
if [[ -f /etc/needrestart/needrestart.conf ]]; then
  sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" \
    /etc/needrestart/needrestart.conf || true
fi

info "Updating packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl socat ca-certificates
ok "Packages ready"

info "Enabling BBR congestion control"
modprobe tcp_bbr 2>/dev/null || true
if ! grep -q '^net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf; then
  cat >> /etc/sysctl.conf <<'EOF'

# --- proxy tuning ---
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
fi
sysctl -p >/dev/null

CC=$(sysctl -n net.ipv4.tcp_congestion_control)
if [[ "$CC" == "bbr" ]]; then
  ok "BBR active"
else
  fail "Congestion control is '$CC', not bbr."
  fail "On OpenVZ/LXC this cannot work — you need KVM."
  exit 1
fi

if [[ -f /var/run/reboot-required ]]; then
  printf '\n%s[!]%s Kernel upgrade pending. Reboot, reconnect, then re-run:\n' "$YELL" "$NC"
  printf '      sysctl net.ipv4.tcp_congestion_control\n'
  printf '    Then run scripts/02-install-3xui.sh\n\n'
else
  ok "No reboot required — continue with scripts/02-install-3xui.sh"
fi
