#!/usr/bin/env bash
# 03-issue-cert-dns.sh — Let's Encrypt wildcard via Cloudflare DNS-01
#
# Cloudflare API token needs BOTH permissions:
#   Zone -> DNS  -> Edit
#   Zone -> Zone -> Read
# Zone Resources: Include -> Specific zone -> your domain
#
# Usage:
#   export CF_Token="..."
#   ./03-issue-cert-dns.sh example.com
set -euo pipefail

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; NC=$'\033[0m'
CERT_DIR=/root/cert

DOMAIN="${1:-}"
[[ -n "$DOMAIN" ]] || { echo "Usage: $0 <domain>"; exit 1; }
[[ -n "${CF_Token:-}" ]] || { echo "${RED}Set CF_Token first:${NC} export CF_Token=\"...\""; exit 1; }

if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
  echo "Installing acme.sh..."
  curl -s https://get.acme.sh | sh -s email="admin@${DOMAIN}"
fi

mkdir -p "$CERT_DIR"

echo "Issuing certificate for ${DOMAIN} and *.${DOMAIN} (2-5 minutes)..."
"$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$DOMAIN" -d "*.${DOMAIN}"

echo "Installing to ${CERT_DIR}..."
"$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --ecc \
  --key-file       "${CERT_DIR}/cert.key" \
  --fullchain-file "${CERT_DIR}/cert.crt" \
  --reloadcmd      "systemctl restart x-ui" \
  || "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
       --key-file       "${CERT_DIR}/cert.key" \
       --fullchain-file "${CERT_DIR}/cert.crt" \
       --reloadcmd      "systemctl restart x-ui"

chmod 600 "${CERT_DIR}/cert.key"

echo
openssl x509 -in "${CERT_DIR}/cert.crt" -noout -issuer -dates
echo
echo "${GREEN}Done.${NC} Point the inbound at:"
echo "  Public Key : ${CERT_DIR}/cert.crt"
echo "  Private Key: ${CERT_DIR}/cert.key"
echo "Renewal is handled by cron every ~60 days."
