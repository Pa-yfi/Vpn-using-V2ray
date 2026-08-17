#!/usr/bin/env bash
# 02-install-3xui.sh — guided 3x-ui install
# Prints the answers to give at each prompt, then hands over to the official installer.
set -euo pipefail

YELL=$'\033[0;33m'; NC=$'\033[0m'; RED=$'\033[0;31m'

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

cat <<EOF
${YELL}Answer the installer prompts as follows:${NC}

  Database type ............ 1  (SQLite)
  Customize panel port ..... y
  Panel port ............... any number ${RED}<= 65535${NC}   <-- larger values crash the panel
  Username / password ...... let it generate randomly
  Web base path ............ let it generate randomly
  SSL setup ................ 1 if a DNS A record already resolves to this host
                             otherwise choose 4 and issue later with
                             scripts/03-issue-cert-dns.sh

Save the credentials printed at the end. They are also written to
/etc/x-ui/install-result.env (mode 600). Run 'x-ui' any time to view or reset them.

EOF

read -r -p "Press Enter to start the installer, Ctrl-C to abort... " _

bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

echo
echo "Verifying service..."
systemctl is-active --quiet x-ui && echo "x-ui: running" || {
  echo "${RED}x-ui not running.${NC} Check the panel port is <= 65535:"
  echo "  journalctl -u x-ui -n 30 --no-pager"
  echo "  x-ui setting -port 52175 && systemctl restart x-ui"
}
