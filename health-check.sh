#!/usr/bin/env bash
# health-check.sh — one-shot diagnostic. Run on the server.
set -uo pipefail

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELL=$'\033[0;33m'; NC=$'\033[0m'
pass() { printf '%s[✓]%s %s\n' "$GREEN" "$NC" "$1"; }
warn() { printf '%s[!]%s %s\n' "$YELL" "$NC" "$1"; }
bad()  { printf '%s[✗]%s %s\n' "$RED" "$NC" "$1"; }

DOMAIN="${1:-}"
CERT=/root/cert/cert.crt

echo "=== congestion control ==="
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
[[ "$CC" == "bbr" ]] && pass "BBR active" || bad "Congestion control = $CC (expected bbr)"

echo; echo "=== x-ui service ==="
systemctl is-active --quiet x-ui && pass "x-ui running" || bad "x-ui not running"

echo; echo "=== listeners ==="
if ss -tlnp 2>/dev/null | grep -q ':443 '; then pass "Reality listening on :443"; else bad "Nothing on :443"; fi
if ss -tlnp 2>/dev/null | grep -q ':8443 '; then pass "WebSocket listening on :8443"; else warn "Nothing on :8443 (Path B not configured?)"; fi

echo; echo "=== certificate ==="
if [[ -f "$CERT" ]]; then
  if openssl x509 -in "$CERT" -noout >/dev/null 2>&1; then
    openssl x509 -in "$CERT" -noout -issuer -dates | sed 's/^/    /'
    END=$(date -d "$(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)" +%s 2>/dev/null || echo 0)
    NOW=$(date +%s); DAYS=$(( (END - NOW) / 86400 ))
    if   (( DAYS < 0 ));  then bad  "Certificate EXPIRED"
    elif (( DAYS < 15 )); then warn "Expires in $DAYS days — check the renewal cron"
    else pass "Valid for $DAYS more days"; fi
  else
    bad "Certificate file is not valid PEM (see E-06)"
  fi
else
  warn "No certificate at $CERT"
fi

if [[ -n "$DOMAIN" ]]; then
  echo; echo "=== local TLS handshake ($DOMAIN) ==="
  OUT=$(openssl s_client -connect 127.0.0.1:8443 -servername "$DOMAIN" </dev/null 2>&1)
  if grep -q 'Verify return code: 0' <<<"$OUT"; then
    pass "Handshake OK"; grep -m1 'issuer=' <<<"$OUT" | sed 's/^/    /'
  elif grep -q 'unrecognized name' <<<"$OUT"; then
    bad "unrecognized name — cert not loaded for this SNI (see E-07)"
  else
    warn "Handshake incomplete"; grep -m1 'issuer=' <<<"$OUT" | sed 's/^/    /' || true
  fi
fi

echo; echo "=== recent errors ==="
if journalctl -u x-ui -n 200 --no-pager 2>/dev/null \
   | grep -E 'ERROR' | grep -v 'use of closed network connection' | tail -5 | grep -q .; then
  journalctl -u x-ui -n 200 --no-pager | grep -E 'ERROR' \
    | grep -v 'use of closed network connection' | tail -5 | sed 's/^/    /'
else
  pass "No significant errors"
fi
