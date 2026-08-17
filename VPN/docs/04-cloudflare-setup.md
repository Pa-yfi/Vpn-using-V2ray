# 04 — Path B: Cloudflare + WebSocket + TLS

## Why not Reality here

Cloudflare terminates TLS at its edge and re-encrypts to the origin. Reality depends on TLS passing through **untouched**. The two cannot coexist — behind a CDN you need a conventional TLS + WebSocket inbound.

```mermaid
flowchart LR
    C["Client"] -->|"TLS #1 — CF edge cert<br/>(publicly trusted)"| CF["Cloudflare"]
    CF -->|"TLS #2 — your origin cert<br/>port 8443"| O["Xray"]
    O --> N(["Internet"])

    style CF fill:#f38020,color:#fff
```

Two separate TLS sessions. **The client never validates your origin certificate** — it only sees Cloudflare's. This is why a Cloudflare Origin Certificate works behind the proxy but breaks any direct connection.

## What Cloudflare does and does not give you

| ✅ Does | ❌ Does not |
|---|---|
| Hides the origin IP from clients | Change your exit IP — sites still see the VPS |
| Survives origin IP blocking | Provide UDP |
| Looks like ordinary CDN traffic | Improve latency (it adds a hop) |
| Free TLS at the edge | Work on arbitrary ports |

## Step 1 — DNS

| Field | Value |
|---|---|
| Type | `A` |
| Name | `cdn` |
| Content | **`SERVER_IP`** |
| Proxy status | **Proxied** (orange) |

Keep a second record for direct access and cert issuance:

| Field | Value |
|---|---|
| Type | `A` |
| Name | `direct` |
| Content | `SERVER_IP` |
| Proxy status | **DNS only** (grey) |

> ⚠️ After proxying, `nslookup cdn.example.com` returns Cloudflare anycast IPs (`104.x`, `172.6x`). **Correct.** Never paste that value back into the record — that causes Error 1000.

## Step 2 — Ports

Cloudflare proxies HTTPS only on:

| `443` · `2053` · `2083` · `2087` · `2096` · `8443` |
|---|

`443` is used by Reality, so use **`8443`**.

## Step 3 — SSL/TLS mode

| Mode | Result |
|---|---|
| Flexible | ❌ CF → origin over plain HTTP; your TLS inbound is never reached |
| Full | ✅ Any cert, including CF Origin Certificate |
| **Full (Strict)** | ✅ Best — requires a publicly trusted cert |

## Step 4 — Inbound

| Tab | Field | Value |
|---|---|---|
| Basics | Protocol | `vless` |
| Basics | **Address** | **BLANK** |
| Basics | Port | `8443` |
| Protocol | Decryption | `none` |
| Stream | Transmission | `WebSocket` |
| Stream | Host | `cdn.example.com` |
| Stream | Path | `/xK9pQ` |
| Security | Security | `TLS` |
| Security | SNI | `cdn.example.com` |
| Security | ALPN | **`http/1.1` only** — remove `h2` |
| Security | uTLS | empty (client-side field) |
| Security | Cert mode | `File Path` |
| Security | Public Key | `/root/cert/cert.crt` |
| Security | Private Key | `/root/cert/cert.key` |
| Client | Flow | **empty** |

## Certificates — two methods

```mermaid
flowchart TD
    Q{"Method"} --> M1["Origin Certificate"]
    Q --> M2["API token + DNS-01"]
    M1 --> A1["✅ 15 years, 2 min setup"]
    M1 --> A2["❌ Only CF trusts it<br/>❌ Direct connections break<br/>❌ Key shown once"]
    M2 --> B1["✅ Trusted everywhere<br/>✅ Wildcard<br/>✅ Auto-renew<br/>✅ Enables Full (Strict)"]
    B1 --> W["★ Recommended"]

    style W fill:#1a7f37,color:#fff
    style A2 fill:#cf222e,color:#fff
```

### Method 1 — Origin Certificate

SSL/TLS → Origin Server → Create Certificate. RSA 2048, hostnames `*.example.com` + `example.com`, 15 years.

> The private key appears **once**. Copy both blocks before leaving the page.

```bash
mkdir -p /root/cert
cat > /root/cert/cert.crt <<'EOF'
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
EOF
cat > /root/cert/cert.key <<'EOF'
-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
EOF
chmod 600 /root/cert/cert.key
openssl x509 -in /root/cert/cert.crt -noout -subject -dates
openssl rsa  -in /root/cert/cert.key -check -noout
systemctl restart x-ui
```

Use a quoted heredoc, not `nano` — editors mangle long PEM lines.

### Method 2 — API token + DNS-01 (recommended)

**Token:** My Profile → API Tokens → Create Token → Custom token.

| Section | Setting |
|---|---|
| Permissions row 1 | `Zone` → `DNS` → **Edit** |
| Permissions row 2 | `Zone` → `Zone` → **Read** |
| Zone Resources | `Include` → `Specific zone` → `example.com` |

> ⚠️ Both permission rows are required — with only `DNS:Edit`, acme.sh cannot resolve the zone ID. And the second row goes under **Permissions**, not Zone Resources.

```bash
export CF_Token="your_token_here"
# export CF_Account_ID="..."   # only if acme.sh asks

~/.acme.sh/acme.sh --issue --dns dns_cf -d example.com -d '*.example.com'

~/.acme.sh/acme.sh --install-cert -d example.com --ecc \
  --key-file       /root/cert/cert.key \
  --fullchain-file /root/cert/cert.crt \
  --reloadcmd      "systemctl restart x-ui"

openssl x509 -in /root/cert/cert.crt -noout -issuer -dates
```

Issuance takes 2–5 minutes (TXT record propagation). Installing to the paths the panel already uses means **no panel edits are needed**. A cron job renews every ~60 days and restarts x-ui automatically.

Once done, switch Cloudflare to **Full (Strict)** and optionally build a direct (non-CF) profile against `direct.example.com`, which now also has a trusted certificate.

## Link template

```
vless://UUID@cdn.example.com:8443
  ?type=ws
  &security=tls
  &encryption=none
  &sni=cdn.example.com
  &host=cdn.example.com
  &path=%2FxK9pQ
  &fp=chrome
  &alpn=http%2F1.1
#CF-Fallback
```

Two silent killers: the path must be **percent-encoded** (`%2F`), and the address must be the **domain**, not `SERVER_IP`.
