# VPN using V2Ray — VLESS Reality + Cloudflare WebSocket

A complete, reproducible build guide for a self-hosted Xray (V2Ray) proxy server with **two independent transports**: a fast direct **Reality** path and a censorship-resilient **WebSocket-behind-Cloudflare** path.

This is not a copy-paste script collection. Every step includes *why* it exists, what breaks when you get it wrong, the **exact log output** of that failure, and how to fix it. It was written from a real end-to-end build, including all the dead ends.

> **Placeholders used throughout**
> | Placeholder | Meaning | Example value in this doc |
> |---|---|---|
> | `SERVER_IP` | Your VPS public IPv4 | `203.0.113.45` |
> | `example.com` | Your domain | your real domain |
> | `cdn.example.com` | **Proxied** subdomain (orange cloud) | Path B endpoint |
> | `direct.example.com` | **DNS-only** subdomain (grey cloud) | Path A / panel |
> | `PANEL_PORT` | 3x-ui web panel port | any value ≤ 65535 |
> | `WEB_PATH` | 3x-ui random base path | generated at install |
> | `UUID` | Client UUID from the panel | generated per client |
> | `WS_PATH` | WebSocket path | `/xK9pQ` |
>
> Never commit real values. See [`.gitignore`](.gitignore).

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [Why two paths](#2-why-two-paths)
3. [Phase 1 — Choosing a VPS](#3-phase-1--choosing-a-vps)
4. [Phase 2 — Server preparation](#4-phase-2--server-preparation)
5. [Phase 3 — Installing 3x-ui](#5-phase-3--installing-3x-ui)
6. [Phase 4 — Path A: VLESS + Reality](#6-phase-4--path-a-vless--reality)
7. [Phase 5 — Path B: VLESS + WS + TLS behind Cloudflare](#7-phase-5--path-b-vless--ws--tls-behind-cloudflare)
8. [Phase 6 — TLS certificates: two methods](#8-phase-6--tls-certificates-two-methods)
9. [The verification ladder](#9-the-verification-ladder)
10. [Error catalog](#10-error-catalog)
11. [Security hardening](#11-security-hardening)
12. [Maintenance & billing traps](#12-maintenance--billing-traps)
13. [Repository structure](#13-repository-structure)
14. [Appendix — rebuild checklist](#14-appendix--rebuild-checklist)

---

## 1. Architecture

```mermaid
flowchart LR
    subgraph CLIENT["Client device"]
        APP["Xray / sing-box client<br/>(v2rayN, Hiddify, v2rayA)"]
    end

    subgraph NET["Internet"]
        DPI{{"DPI / filtering<br/>layer"}}
        CF["Cloudflare edge<br/>(anycast IPs)"]
    end

    subgraph VPS["VPS — Germany"]
        X["Xray core"]
        P1["Inbound A<br/>:443 VLESS + Reality<br/>transport RAW"]
        P2["Inbound B<br/>:8443 VLESS + WS + TLS<br/>path WS_PATH"]
        PANEL["3x-ui panel<br/>:PANEL_PORT"]
    end

    OUT(["Open internet"])

    APP -- "Path A — direct<br/>looks like TLS to a real site" --> DPI
    DPI --> P1
    APP -- "Path B — via CDN<br/>looks like normal HTTPS" --> DPI
    DPI --> CF
    CF -- "TLS to origin :8443" --> P2
    P1 --> X
    P2 --> X
    X --> OUT
    PANEL -.->|"config only"| X

    style P1 fill:#1f6feb,color:#fff
    style P2 fill:#8250df,color:#fff
    style CF fill:#f38020,color:#fff
    style DPI fill:#cf222e,color:#fff
```

**Key insight:** both inbounds live in the *same* Xray process, driven by the same 3x-ui panel. One misconfigured inbound takes down **both** — see [E-05](#e-05--unable-to-listen-on-domain-address).

---

## 2. Why two paths

| | **Path A — Reality** | **Path B — WS + TLS + Cloudflare** |
|---|---|---|
| Port | `443` | `8443` (via CF) |
| Transport | RAW (TCP) | WebSocket |
| TLS | Borrowed from a real site (no cert needed) | Real cert on origin + CF edge cert |
| **UDP support** | ✅ Yes (XUDP) — calls, games, QUIC | ❌ No (TCP only) |
| Latency | Lower (one hop) | Higher (CDN detour) |
| Survives server IP blocking | ❌ No | ✅ Yes — client only ever talks to CF IPs |
| Needs a domain | No | Yes |
| Detection surface | TLS fingerprint | Standard CDN traffic |
| **Use as** | Daily driver | Fallback / Plan B |

> **Common misconception:** putting Cloudflare in front does **not** change your exit IP. Websites still see the VPS (Germany). CF only shields the *path* between client and server. If you want a Cloudflare exit IP, that requires a Worker-based tunnel, which has no UDP and strict usage limits.

```mermaid
flowchart TD
    Q1{"Is the server IP<br/>reachable from your ISP?"}
    Q1 -- Yes --> A["Use Path A (Reality)<br/>faster + UDP"]
    Q1 -- No / blocked --> B["Switch to Path B (CF)<br/>keeps working after IP blocks"]
    A --> Q2{"Need UDP?<br/>(voice, gaming, QUIC)"}
    Q2 -- Yes --> A2["Path A is the only option"]
    Q2 -- No --> A3["Either works"]

    style A fill:#1f6feb,color:#fff
    style B fill:#8250df,color:#fff
```

---

## 3. Phase 1 — Choosing a VPS

This phase decides more about your final experience than any config setting. A perfect config on a bad IP is useless.

```mermaid
flowchart TD
    START([Start]) --> J{"Where will you<br/>connect FROM?"}
    J -- "Sanctioned region" --> S1["❌ Avoid US-owned providers<br/>(OFAC → account suspension)"]
    J -- "Unrestricted region" --> S2["Most providers fine"]
    S1 --> L{"Pick a location"}
    S2 --> L
    L --> L1["🇩🇪 Germany / 🇳🇱 NL / 🇫🇮 FI<br/>stable, major peering"]
    L --> L2["🇹🇷 TR / 🇦🇲 AM / 🇦🇪 AE<br/>lower latency, fresher IP ranges"]
    L --> L3["🇷🇺 RU — ❌ avoid<br/>local DPI adds a 2nd problem"]
    L1 --> SPEC
    L2 --> SPEC
    SPEC["Specs that actually matter"] --> SP1["KVM virtualization (BBR needs it)"]
    SPEC --> SP2["≥1 Gbps port ← biggest impact"]
    SPEC --> SP3["1 vCPU / 1 GB RAM is plenty"]
    SPEC --> SP4["Unlimited or ≥2 TB traffic"]
    SP4 --> REP{"Provider reputation<br/>check"}
    REP -- "Sanctioned / bulletproof host" --> RB["❌ Dirty IP ranges =<br/>constant CAPTCHAs, blocklists"]
    REP -- "Clean" --> BUY["✅ Buy MONTHLY first"]

    style L3 fill:#cf222e,color:#fff
    style RB fill:#cf222e,color:#fff
    style S1 fill:#cf222e,color:#fff
    style BUY fill:#1a7f37,color:#fff
```

### Filter settings that actually matter

| Setting | Value | Why |
|---|---|---|
| Virtualization | **KVM** | OpenVZ/LXC can't load the BBR kernel module and is heavily oversold |
| Network speed | **≥ 1000 Mbps** | The single biggest factor in perceived speed |
| RAM | **1 GB** | Xray + panel fit comfortably; more RAM does *not* make a proxy faster |
| Bandwidth | Unlimited or ≥ 2 TB/mo | VPN traffic is the whole workload |
| Management | Unmanaged | Cheaper; you're doing this yourself |
| DDoS protection | **Off** | Costs more, and scrubbing layers hurt latency and TLS handshakes |

### Do **not** buy these add-ons

| Upsell | Verdict |
|---|---|
| Control panel license (ISPmanager, cPanel, Hestia) | ❌ Useless here, expands attack surface |
| SSL certificate | ❌ Reality needs none; Let's Encrypt is free |
| DNS hosting | ❌ Cloudflare already does this |
| Extra IPs | ❌ One is enough |
| Backups | ❌ Rebuild takes 15 minutes |

> 💡 **Buy monthly for the first month.** If the IP turns out to be blocked from your ISP, you haven't burned a year of prepayment. Only commit long-term once the IP proves itself.

---

## 4. Phase 2 — Server preparation

SSH in as root. First, base packages:

```bash
apt update && apt upgrade -y
apt install -y curl socat
```

### The `needrestart` prompt

During upgrades, Ubuntu 22.04 interrupts with:

```
Daemons using outdated libraries
--------------------------------
  1. getty@tty1.service  2. user@0.service
(Enter the items or ranges you want to select, separated by spaces.)
Which services should be restarted?
```

Type `1 2` and press Enter. Safe — `sshd` is not in the list, so your session survives. To stop it appearing again:

```bash
sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
```

### Enable BBR (do this *before* installing the panel)

BBR is Google's congestion-control algorithm. On long, lossy international routes it is the single highest-impact tuning change available.

```bash
modprobe tcp_bbr
cat >> /etc/sysctl.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p
```

**Verify — do not skip this:**

```bash
sysctl net.ipv4.tcp_congestion_control
```

| Output | Meaning |
|---|---|
| `net.ipv4.tcp_congestion_control = bbr` | ✅ Active |
| `... = cubic` | ❌ Not applied. Re-run the block above; on OpenVZ/LXC it will never work |

### Reboot if the kernel was upgraded

```bash
ls /var/run/reboot-required && reboot
```

Wait ~30 s, then reconnect.

---

## 5. Phase 3 — Installing 3x-ui

> ⚠️ `apt install x-ui` **does not work** — see [E-01](#e-01-e-unable-to-locate-package-x-ui). It is installed from the project's own script.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
```

### Answering the installer

| Prompt | Answer | Why |
|---|---|---|
| Database type | `1` — **SQLite** | Correct for personal use (<500 clients) |
| Customize panel port? | `y` | Never leave a predictable port |
| Panel port | **any number ≤ 65535** | ⚠️ See [E-03](#e-03--panel-crashes-with-exit-status-1) |
| Username / password | Let it generate random | Stronger than anything you'll type |
| Web base path | Let it generate random | Acts as a second secret; the panel is invisible without it |
| SSL setup | See table below | |

### SSL options at install time

| Option | When to choose |
|---|---|
| 1 — Let's Encrypt for **domain** | ✅ Best. **Requires a DNS A record to already exist** (see [E-04](#e-04-no-valid-a-records-found)) |
| 2 — Let's Encrypt for **IP** | Works, but 6-day validity — a single renewal hiccup breaks panel access |
| 3 — Custom certificate | If you already have files on disk |
| 4 — Skip | Only behind a reverse proxy or SSH tunnel |

**At the end the installer prints your credentials once.** Store them in a password manager immediately:

```
Username:    ██████████
Password:    ██████████
Port:        PANEL_PORT
WebBasePath: ██████████████████
Access URL:  https://SERVER_IP:PANEL_PORT/WEB_PATH
API Token:   ████████████████████████████████
```

They are also written to `/etc/x-ui/install-result.env` (mode 600). To view or reset them later, run `x-ui` and use the menu.

---

## 6. Phase 4 — Path A: VLESS + Reality

### How Reality works

```mermaid
sequenceDiagram
    participant C as Client
    participant S as Your server :443
    participant R as Real site (SNI target)

    C->>S: TLS ClientHello (SNI = www.speedtest.net)
    Note over S: Inspect the embedded auth data
    alt Auth valid (correct pubkey + shortId + version)
        S-->>C: Acts as proxy — tunnel established
        Note over C,S: Traffic is indistinguishable<br/>from a real TLS session
    else Auth invalid
        S->>R: Silently forwards the whole connection
        R-->>C: Real site's genuine TLS response
        Note over C,S: ⚠️ NO error, NO log entry,<br/>0 bytes — client just times out
    end
```

**This silent-failure design is why Reality is hard to debug.** A wrong key, a wrong shortId, or a rejected client version all produce the *exact same symptom*: an endless "Connecting…" with zero bytes and nothing in the server log. You cannot troubleshoot Reality by reading logs; you troubleshoot it by elimination.

### Inbound settings, tab by tab

**Basics**

| Field | Value | Notes |
|---|---|---|
| Protocol | `vless` | |
| **Address** | **LEAVE BLANK** | ⚠️ This means "which local IP to bind". Entering a domain kills Xray — [E-05](#e-05--unable-to-listen-on-domain-address) |
| Port | `443` | |
| Remark | anything memorable | |

**Protocol**

| Field | Value | Notes |
|---|---|---|
| Decryption | `none` | Press **Clear** if it's pre-filled with `mlkem768x25519plus...`. That's VLESS native encryption; sing-box-based clients don't support it and fail silently |
| Encryption | empty | |

**Stream**

| Field | Value |
|---|---|
| Transmission | `RAW` (TCP) |
| Everything else | default / off |

**Security → Reality**

| Field | Value | Notes |
|---|---|---|
| Target (`dest`) | `www.speedtest.net:443` | Must be a real, reachable HTTPS site with TLS 1.3 |
| SNI / Server Names | `www.speedtest.net` | Same host as Target, **without** the port |
| uTLS | `chrome` | |
| Public / Private key | click **Generate** | Never hand-write these |
| Short IDs | **one** is enough | Delete the extras; fewer chances to mistype |
| SpiderX | default | |
| **Min Client Ver** | see below ⚠️ | |
| Max Client Ver | empty | |

**Client (inside the inbound)**

| Field | Value |
|---|---|
| Flow | `xtls-rprx-vision` |

### ⚠️ The `minClientVer` trap

Recent Xray-core builds set a **default** minimum client version for Reality even when the field is blank. Clients that don't report a modern Xray version — sing-box-based apps such as Hiddify, and mihomo — get rejected **silently**.

You'll see this warning at startup:

```
[Warning] infra/conf: REALITY: The default minimal client version is Xray-core vXX.X.XX,
other clients may be refused to connect
```

Two ways forward:

| Option | Action | Trade-off |
|---|---|---|
| **A (recommended)** | Leave `minClientVer` blank, use a client with a real **Xray core** (v2rayN, v2rayA) | Keeps the strongest fingerprint protection |
| **B** | Set `minClientVer` explicitly to a low value, e.g. `1.8.0` | Lets sing-box clients in, but older TLS fingerprints differ from a real browser and are more distinguishable by DPI |

If you choose B, the server will remind you at every start:

```
[Warning] infra/conf: REALITY: Changing "minClientVer" will increase the
likelihood of your server's IP being blocked by the GFW
```

### Client link format

```
vless://UUID@SERVER_IP:443?type=tcp&security=reality&encryption=none
&pbk=PUBLIC_KEY&fp=chrome&sni=www.speedtest.net&sid=SHORT_ID
&spx=%2F&flow=xtls-rprx-vision#Reality-Direct
```

Always copy the link/QR from the panel rather than typing it. A single wrong character in `pbk` or `sid` produces a silent failure identical to every other Reality error.

---

## 7. Phase 5 — Path B: VLESS + WS + TLS behind Cloudflare

### Why WebSocket and not Reality here

Cloudflare terminates TLS at its edge and re-encrypts to your origin. Reality's entire premise is that TLS passes through *untouched*, so the two are fundamentally incompatible. Behind a CDN you need a plain TLS + WebSocket inbound.

```mermaid
flowchart LR
    C["Client"] -->|"TLS #1<br/>CF edge cert"| CF["Cloudflare edge"]
    CF -->|"TLS #2<br/>your origin cert<br/>port 8443"| O["Xray on VPS"]
    O --> NET(["Internet"])

    style CF fill:#f38020,color:#fff
```

Two independent TLS sessions. This is why **the client never validates your origin certificate** — it only ever sees Cloudflare's.

### Step 1 — DNS record

In Cloudflare → DNS → Records:

| Field | Value |
|---|---|
| Type | `A` |
| Name | `cdn` (→ `cdn.example.com`) |
| Content | **`SERVER_IP`** ← your VPS IP |
| Proxy status | **Proxied** (orange cloud) |
| TTL | Auto |

> ⚠️ **Put your server's IP in `Content` — not the IP that `nslookup` returns.** After proxying is enabled, external DNS lookups return Cloudflare's anycast IPs (`104.x.x.x`, `172.6x.x.x`). That is correct and expected. Copying that value back into the record causes [E-08 (Error 1000)](#e-08--cloudflare-error-1000).

### Step 2 — Port choice

Cloudflare only proxies HTTPS on a fixed set of origin ports:

| Supported HTTPS ports |
|---|
| `443`, `2053`, `2083`, `2087`, `2096`, **`8443`** |

`443` is already taken by Reality, so **`8443`** is the natural choice.

### Step 3 — SSL/TLS mode

Cloudflare → SSL/TLS → Overview:

| Mode | Result |
|---|---|
| Flexible | ❌ CF connects to origin over **plain HTTP** — your TLS inbound is never reached |
| **Full** | ✅ Works with any cert, including self-signed / CF Origin Certificate |
| **Full (Strict)** | ✅ Best — requires a publicly trusted cert (see [Method 2](#method-2--api-token--dns-01-recommended)) |

### Step 4 — Inbound settings

**Basics**

| Field | Value |
|---|---|
| Protocol | `vless` |
| **Address** | **LEAVE BLANK** |
| Port | `8443` |

**Stream**

| Field | Value |
|---|---|
| Transmission | `WebSocket` |
| Host | `cdn.example.com` |
| Path | `WS_PATH` (e.g. `/xK9pQ`) |

**Security → TLS**

| Field | Value | Notes |
|---|---|---|
| Security | `TLS` | |
| SNI | `cdn.example.com` | ⚠️ Not the Reality SNI — a very common copy-paste error |
| ALPN | **`http/1.1` only** | Remove `h2`. Cloudflare speaks HTTP/1.1 to origins for WebSocket |
| uTLS | empty | Client-side field; irrelevant on an inbound |
| Certificate mode | `File Path` | |
| Public Key | `/root/cert/cert.crt` | |
| Private Key | `/root/cert/cert.key` | |
| Min/Max version | `1.2` / `1.3` | |

**Client**

| Field | Value |
|---|---|
| Flow | **empty** — `xtls-rprx-vision` is incompatible with WebSocket |

### Step 5 — Client link format

```
vless://UUID@cdn.example.com:8443?type=ws&security=tls&encryption=none
&sni=cdn.example.com&host=cdn.example.com&path=%2FxK9pQ
&fp=chrome&alpn=http%2F1.1#CF-Fallback
```

Two details that silently break this link:

- The path **must** be percent-encoded: `%2FxK9pQ`, not `/xK9pQ`.
- The address must be **`cdn.example.com`**, not `SERVER_IP`. Since the `Address` field is blank, 3x-ui defaults to putting the raw IP in generated links — edit it, or set the panel's **External Proxy** field to the domain so it generates correct links automatically.

---

## 8. Phase 6 — TLS certificates: two methods

```mermaid
flowchart TD
    START(["Need a cert for the origin"]) --> Q{"Which method?"}
    Q --> M1["Method 1<br/>Cloudflare Origin Certificate"]
    Q --> M2["Method 2<br/>API token + DNS-01 → Let's Encrypt"]

    M1 --> M1a["✅ 15-year validity<br/>✅ 2 minutes of clicking"]
    M1 --> M1b["❌ Only Cloudflare trusts it<br/>❌ Breaks direct (non-CF) connections<br/>❌ Private key shown ONCE"]

    M2 --> M2a["✅ Publicly trusted everywhere<br/>✅ Wildcard possible<br/>✅ Auto-renews via cron<br/>✅ Enables Full (Strict)"]
    M2 --> M2b["❌ Requires API token setup"]

    M2a --> WIN["★ Recommended"]

    style WIN fill:#1a7f37,color:#fff
    style M1b fill:#cf222e,color:#fff
```

### Method 1 — Cloudflare Origin Certificate

Cloudflare → SSL/TLS → Origin Server → **Create Certificate**.

| Field | Value |
|---|---|
| Key type | RSA (2048) |
| Hostnames | `*.example.com`, `example.com` (the wildcard covers every subdomain) |
| Validity | 15 years |

> ⚠️ **The private key is displayed exactly once.** Close the page without copying it and the certificate is unusable — you must issue a new one.

Paste both blocks onto the server. **Use `cat` with a quoted heredoc, not `nano`** — editors can wrap or mangle long PEM lines ([E-06](#e-06-could-not-read-certificate)):

```bash
mkdir -p /root/cert

cat > /root/cert/cert.crt <<'EOF'
-----BEGIN CERTIFICATE-----
...paste the Origin Certificate block...
-----END CERTIFICATE-----
EOF

cat > /root/cert/cert.key <<'EOF'
-----BEGIN PRIVATE KEY-----
...paste the Private Key block...
-----END PRIVATE KEY-----
EOF

chmod 600 /root/cert/cert.key
```

**Validate before touching the panel:**

```bash
openssl x509 -in /root/cert/cert.crt -noout -subject -dates
openssl rsa  -in /root/cert/cert.key -check -noout
```

Both must succeed. Then `systemctl restart x-ui` — certificate changes are **not** picked up by the live-reload API.

### Method 2 — API token + DNS-01 (recommended)

This produces a genuine Let's Encrypt certificate that every client trusts, renews itself, and works on both proxied and direct subdomains.

**Create the token:** Cloudflare → My Profile → API Tokens → Create Token → Custom token.

| Section | Setting |
|---|---|
| Permissions row 1 | `Zone` → `DNS` → **Edit** |
| Permissions row 2 | `Zone` → `Zone` → **Read** |
| Zone Resources | `Include` → `Specific zone` → `example.com` |
| Client IP filtering | leave empty |
| TTL | leave empty |

> ⚠️ **Both permission rows are required.** With only `DNS:Edit`, acme.sh can create the TXT record but cannot look up the zone ID, and fails. Also note the second row belongs under **Permissions**, not under Zone Resources — adding a second *Zone Resources* row does nothing useful.

**Issue the certificate:**

```bash
export CF_Token="your_token_here"

~/.acme.sh/acme.sh --issue --dns dns_cf \
  -d example.com -d '*.example.com'
```

Takes 2–5 minutes: acme.sh creates a TXT record, waits for DNS propagation, gets validated, then cleans up. Don't interrupt it. If it asks for an account ID, grab it from the domain's Overview page and `export CF_Account_ID="..."` too.

**Install to the paths the panel already points at**, so no panel edits are needed:

```bash
~/.acme.sh/acme.sh --install-cert -d example.com --ecc \
  --key-file       /root/cert/cert.key \
  --fullchain-file /root/cert/cert.crt \
  --reloadcmd      "systemctl restart x-ui"
```

(Drop `--ecc` if it errors.)

**Verify:**

```bash
openssl x509 -in /root/cert/cert.crt -noout -issuer -dates
```

```
issuer=C = US, O = Let's Encrypt, CN = ...
notBefore=...
notAfter=...        ← ~90 days out
```

The token is saved in `~/.acme.sh/account.conf` and a cron job renews every 60 days, restarting x-ui automatically. Once this is in place, switch Cloudflare to **Full (Strict)**.

---

## 9. The verification ladder

When something doesn't connect, **do not guess**. Walk the ladder — each rung isolates one segment of the path.

```mermaid
flowchart TD
    S(["Client won't connect"]) --> L1["1️⃣ ss -tlnp | grep -E ':443|:8443'<br/><i>on server</i>"]
    L1 -- "no output" --> F1["❌ Xray isn't listening<br/>→ journalctl -u x-ui -n 50"]
    L1 -- "listening" --> L2["2️⃣ Test-NetConnection SERVER_IP -Port 443<br/><i>on client, VPN off</i>"]
    L2 -- "False" --> F2["❌ Route blocked / IP filtered<br/>→ open a ticket for an IP change,<br/>or use Path B"]
    L2 -- "True" --> L3["3️⃣ openssl s_client -connect 127.0.0.1:8443<br/><i>on server</i>"]
    L3 -- "handshake error" --> F3["❌ Cert not loaded<br/>→ E-06 / E-07"]
    L3 -- "issuer shown" --> L4["4️⃣ curl -v https://cdn.example.com:8443/WS_PATH<br/><i>on client</i>"]
    L4 -- "525" --> F4["❌ CF↔origin TLS failed → E-07"]
    L4 -- "521 / 522" --> F5["❌ Port closed / timeout"]
    L4 -- "Error 1000" --> F6["❌ DNS points at a CF IP → E-08"]
    L4 -- "400 Bad Request<br/>+ Sec-Websocket-Version" --> OK["✅ SERVER IS FINE<br/>The bug is in your client link"]
    OK --> L5["5️⃣ Compare link params<br/>address / sni / host / path / flow"]

    style OK fill:#1a7f37,color:#fff
    style F2 fill:#cf222e,color:#fff
```

### Reference commands

| # | Where | Command | Healthy output |
|---|---|---|---|
| 1 | server | `ss -tlnp \| grep -E ':443\|:8443'` | one `LISTEN` line per inbound, owned by `xray-linux-amd6` |
| 2 | client | `Test-NetConnection SERVER_IP -Port 443` | `TcpTestSucceeded : True` |
| 3 | server | `openssl s_client -connect 127.0.0.1:8443 -servername cdn.example.com </dev/null 2>&1 \| grep -E "issuer\|Verify"` | `issuer=... Let's Encrypt` + `Verify return code: 0 (ok)` |
| 4 | client | `curl.exe -v https://cdn.example.com:8443/WS_PATH` | `HTTP/1.1 400 Bad Request` + `Sec-Websocket-Version: 13` |
| 5 | server | `journalctl -u x-ui -f` | no `ERROR` lines on startup |

> 🎯 **`400 Bad Request` with a `Sec-Websocket-Version: 13` header is the success signal.** It means Xray itself answered and is complaining that your plain `GET` wasn't a WebSocket upgrade — exactly right. Everything from the client through Cloudflare to Xray works; anything still broken is in the client link.

---

## 10. Error catalog

Every error below was hit in a real build. Sorted by the phase where it appears.

| ID | Symptom | Phase | Severity |
|---|---|---|---|
| [E-01](#e-01-e-unable-to-locate-package-x-ui) | `E: Unable to locate package x-ui` | Install | Trivial |
| [E-02](#e-02-benign-log-noise) | `use of closed network connection` | Any | **Benign** |
| [E-03](#e-03--panel-crashes-with-exit-status-1) | Panel service restart-loops | Install | Blocking |
| [E-04](#e-04-no-valid-a-records-found) | Certificate issuance fails | TLS | Blocking |
| [E-05](#e-05--unable-to-listen-on-domain-address) | **All** inbounds die at once | Inbound | Critical |
| [E-06](#e-06-could-not-read-certificate) | `Unable to load certificate` | TLS | Blocking |
| [E-07](#e-07--cloudflare-525) | Cloudflare `525` | Path B | Blocking |
| [E-08](#e-08--cloudflare-error-1000) | Cloudflare `Error 1000` | Path B | Blocking |
| [E-09](#e-09--silent-timeout-0-bytes) | Endless "Connecting…", 0 bytes, no logs | Path A | **Hardest** |
| [E-10](#e-10--client-link-uses-the-ip-instead-of-the-domain) | Path B times out although curl returns 400 | Path B | Blocking |

---

### E-01 `E: Unable to locate package x-ui`

```console
root@server:~# sudo apt install x-ui
Reading package lists... Done
E: Unable to locate package x-ui
```

**Cause:** 3x-ui isn't in Ubuntu's repositories.
**Fix:** install from the project script — see [Phase 3](#5-phase-3--installing-3x-ui). Also remove any stray directory you created: `rmdir x-ui`.

---

### E-02 Benign log noise

These are **not** failures. Don't chase them.

```
ERROR - XRAY: transport/internet/websocket: failed to serve http for WebSocket >
accept tcp [::]:38725: use of closed network connection
```
→ A listener closed because you edited/deleted an inbound. Normal.

```
[Warning] common/errors: The feature WebSocket transport (with ALPN http/1.1, etc.)
is deprecated, not recommended for using and might be removed.
```
→ Upstream deprecation notice. WebSocket still works and remains the correct choice behind Cloudflare.

```
verify error:num=20:unable to get local issuer certificate
```
→ Only appears with a **Cloudflare Origin Certificate**, whose CA isn't in the system trust store. Cloudflare itself trusts it; harmless in `Full` mode. Disappears entirely with Method 2.

---

### E-03 — Panel crashes with `exit status 1`

```console
● x-ui.service - x-ui Service
     Active: activating (auto-restart) (Result: exit-code)
    Process: 905 ExecStart=/usr/local/x-ui/x-ui (code=exited, status=1/FAILURE)
```

**Cause:** an invalid panel port. TCP ports max out at **65535**; the installer accepts a larger number without validating it, then the panel can't bind.

**Fix:**

```bash
x-ui setting -port 52175      # any value ≤ 65535
systemctl restart x-ui
journalctl -u x-ui -n 30 --no-pager
```

---

### E-04 `no valid A records found`

```console
[...] Verifying: example.com
[...] example.com: Invalid status. Verification error details:
      no valid A records found for example.com;
      no valid AAAA records found for example.com
Issuing certificate failed, please check logs.
```

Note the installer may still print `⚠ SSL Certificate: Enabled and configured` afterwards — **that line is hardcoded and lies**. Always verify independently.

**Cause:** HTTP-01 validation needs the hostname to already resolve to this server.

**Fix — either:**
- Create a **DNS-only (grey cloud)** A record first, wait for propagation, verify with `dig +short direct.example.com`, then retry; or
- Use [Method 2](#method-2--api-token--dns-01-recommended) (DNS-01), which needs no A record at all and works behind the orange cloud.

---

### E-05 — `unable to listen on domain address`

```console
ERROR - XRAY: Failed to start: main: failed to load config files: [bin/config.json] >
infra/conf: failed to build inbound config with tag in-8443-tcp >
infra/conf: unable to listen on domain address: cdn.example.com
ERROR - Failure in running xray-core: exit status 23
```

**Cause:** a domain name was typed into the **Address** field on the *Basics* tab. That field means "which local IP should Xray bind to" — it accepts an IP or nothing, never a hostname.

> 🔥 **This is the most dangerous error in the whole build:** one bad inbound prevents the *entire* Xray process from starting, so your working Reality inbound goes down too.

**Fix:** clear the **Address** field (placeholder should read *"Leave blank to listen on all IPs"*), save, then:

```bash
systemctl restart x-ui
ss -tlnp | grep -E ':443|:8443'
```

**Where the domain *does* belong:**

| Location | Value |
|---|---|
| Stream → Host | `cdn.example.com` |
| Security → SNI | `cdn.example.com` |
| Client link address | `cdn.example.com` |
| Basics → Address | ❌ **always blank** |

---

### E-06 `Could not read certificate`

```console
root@server:~# openssl x509 -in /root/cert/cert.crt -noout -subject -dates
Could not read certificate from /root/cert/cert.crt
Unable to load certificate
```

The file exists and has a non-zero size, but isn't valid PEM.

**Diagnose:**

```bash
head -1 /root/cert/cert.crt   # must be: -----BEGIN CERTIFICATE-----
tail -1 /root/cert/cert.crt   # must be: -----END CERTIFICATE-----
head -1 /root/cert/cert.key   # must be: -----BEGIN PRIVATE KEY-----
```

| Finding | Cause |
|---|---|
| `.crt` starts with `BEGIN PRIVATE KEY` | The two files were swapped |
| BEGIN/END lines missing or truncated | Copy from the browser dropped a line |
| Lines run together | The editor wrapped them |

**Fix:** re-paste using `cat > file <<'EOF'` (quoted heredoc — no wrapping, no variable expansion), then re-validate and **restart the service** — certificate changes don't hot-reload.

---

### E-07 — Cloudflare `525`

```console
< HTTP/1.1 525 <none>
< Server: cloudflare
error code: 525
```

**Meaning:** Cloudflare reached your server but the **TLS handshake between CF and the origin failed**. Network and firewall are fine; this is purely a certificate problem.

**Confirm from the server:**

```bash
openssl s_client -connect 127.0.0.1:8443 -servername cdn.example.com </dev/null 2>&1 | head -20
```

```
error:0A000458:SSL routines:ssl3_read_bytes:tlsv1 unrecognized name
no peer certificate available
```

That `unrecognized name` means Xray has **no usable certificate** for that SNI.

**Checklist:**

1. `openssl x509 -in /root/cert/cert.crt -noout -subject` succeeds → else [E-06](#e-06-could-not-read-certificate)
2. `openssl rsa -in /root/cert/cert.key -check -noout` returns `RSA key ok`
3. Panel: Public Key = `.crt`, Private Key = `.key` (not swapped), mode = **File Path**
4. Panel: SNI = `cdn.example.com`, **not** the Reality SNI
5. `systemctl restart x-ui` — mandatory after any cert change
6. Cloudflare SSL/TLS mode is `Full` or `Full (Strict)`, never `Flexible`

**Healthy result:**

```
issuer=C = US, O = Let's Encrypt, CN = ...
New, TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256
Verify return code: 0 (ok)
```

---

### E-08 — Cloudflare `Error 1000`

```
Error 1000 — DNS points to prohibited IP
You've requested a page on a website (cdn.example.com) that is on the Cloudflare
network. Unfortunately, it is resolving to an IP address that is creating a
conflict within Cloudflare's system.
```

**Cause:** the A record's `Content` holds a **Cloudflare** IP (e.g. `172.64.x.x`) instead of your server's. Cloudflare refuses to proxy to itself.

This usually happens after running `nslookup`, seeing the anycast IP, and pasting it back into the dashboard.

**Fix:** set `Content` = `SERVER_IP` (your VPS), proxy status **Proxied**.

```mermaid
flowchart LR
    D["Dashboard record<br/>Content = SERVER_IP ✅"] --> CFN["Cloudflare"]
    CFN --> R["What the world resolves:<br/>172.64.x.x (CF anycast)"]
    R -. "❌ never copy this back<br/>into the record" .-> D

    style R fill:#f38020,color:#fff
```

Both facts are true at the same time — **that is how proxying works.**

---

### E-09 — Silent timeout, 0 bytes

**Symptom:** client shows "Connecting… / Timeout" forever. Traffic counter reads `0 B`. Server logs show **nothing at all** during the attempt.

This is Reality's fallback behaving as designed: bad auth is forwarded to the real destination site, so the client gets a genuine TLS response that isn't a proxy, and the server never logs a rejection.

**Ranked causes:**

| # | Cause | Fix |
|---|---|---|
| 1 | `minClientVer` default rejects non-Xray clients | See [the trap](#️-the-minclientver-trap) — set `1.8.0` or switch to an Xray-core client |
| 2 | `Decryption` left as `mlkem768x25519plus...` | Press **Clear** → `none` |
| 3 | Stale client profile after editing the inbound | **Delete** the profile, re-import fresh — editing isn't enough |
| 4 | Hand-typed `pbk` / `sid` | Always copy the panel's link or QR |
| 5 | `flow` mismatch | Reality → `xtls-rprx-vision`; WebSocket → empty |
| 6 | Client uses sing-box, server expects Xray | Test with v2rayN / v2rayA to isolate |

**Isolation trick:** get the same UUID working in a second client with a different core. If v2rayN connects and Hiddify doesn't, it's a client-core compatibility issue, not a server issue.

---

### E-10 — Client link uses the IP instead of the domain

**Symptom:** `curl` to `https://cdn.example.com:8443/WS_PATH` returns a healthy `400 Bad Request`, yet the client still hangs.

**Cause:** because **Address** is (correctly) blank, 3x-ui writes `SERVER_IP` into generated links. The client then connects **directly** to the origin, bypassing Cloudflare, and — if you used a Cloudflare Origin Certificate — hits a certificate no client trusts. Silent failure.

**Fix — pick one:**

- Edit the link so the host is `cdn.example.com`, or
- Set the inbound's **External Proxy** to `cdn.example.com` : `8443` so the panel generates correct links from then on.

**Verify the link contains:**

```
@cdn.example.com:8443   ← not the IP
type=ws
security=tls
sni=cdn.example.com
host=cdn.example.com
path=%2FxK9pQ           ← percent-encoded
alpn=http%2F1.1
(no flow parameter)
```

---

## 11. Security hardening

| Item | Action |
|---|---|
| **Rotate anything ever pasted into a chat, screenshot, or issue** | `x-ui` menu → reset username / password / web path / API token; regenerate Reality keypair, then re-export links |
| Panel port | Non-default, ≥ 5 digits, never `2053`/`54321` |
| Web base path | Long and random — the panel 404s without it |
| Key file permissions | `chmod 600 /root/cert/*.key` |
| SSH | Key-based auth; disable password login |
| Panel exposure | Ideally reachable only over an SSH tunnel or from known IPs |
| Fail2ban | Installed automatically by 3x-ui for the IP-limit feature — leave it on |
| `minClientVer` | Return to blank once you move to an Xray-core client |
| Screenshots | Private keys, UUIDs and API tokens are readable in images — crop or redact |

> 🔐 Treat the Reality **private key**, the client **UUID**, and the panel **API token** as passwords of equal weight. Any one of them is enough to use or hijack your server.

---

## 12. Maintenance & billing traps

```mermaid
gantt
    title Recurring maintenance
    dateFormat YYYY-MM-DD
    axisFormat %b %d
    section Certificates
    Let's Encrypt auto-renew (cron, ~60d)   :done, 2026-01-01, 60d
    section Billing
    Monthly VPS renewal                     :crit, 2026-01-01, 30d
    Reminder — 3 days before                :milestone, 2026-01-27, 0d
    section Checks
    Verify BBR + listeners after reboot     :2026-01-01, 7d
```

| Trap | Consequence | Prevention |
|---|---|---|
| **Auto-renewal disabled** | Server deleted → **you lose the IP** → every client link must be rebuilt and redistributed | Enable auto-renew, or set a calendar reminder 3 days early |
| Paying via a gateway that credits **account balance** instead of the invoice | Order sits in "Awaiting payment" while your money sits in the wallet | After topping up, pay the invoice **from account balance** — never re-run the card |
| Repeated payment attempts | Multiple authorization holds; some post as real charges | Stop after the first attempt; open a support ticket instead of retrying |
| Currency + gateway fees | ~10 % gateway commission + ~2.5 % FX on top of list price | Compare *final* charges, not sticker price |
| Kernel upgrades | BBR reverts to `cubic` if config was never persisted | Re-check `sysctl net.ipv4.tcp_congestion_control` after reboots |

**Post-reboot health check:**

```bash
sysctl net.ipv4.tcp_congestion_control     # expect: bbr
x-ui status                                # expect: running
ss -tlnp | grep -E ':443|:8443'            # expect: both inbounds
openssl x509 -in /root/cert/cert.crt -noout -dates
```

---

## 13. Repository structure

```
.
├── README.md                       ← you are here
├── LICENSE
├── .gitignore                      ← keeps secrets out of git
├── docs/
│   ├── 01-vps-selection.md         provider criteria, red flags, cost model
│   ├── 02-server-setup.md          BBR, kernel, base packages
│   ├── 03-reality-inbound.md       Path A deep dive
│   ├── 04-cloudflare-setup.md      DNS, ports, SSL modes, both cert methods
│   ├── 05-troubleshooting.md       full error catalog with raw logs
│   └── 06-security.md              hardening + key rotation
├── scripts/
│   ├── 01-server-prep.sh           packages + BBR + verification
│   ├── 02-install-3xui.sh          guided install wrapper
│   ├── 03-issue-cert-dns.sh        acme.sh DNS-01 via Cloudflare token
│   └── health-check.sh             one-shot diagnostic
└── examples/
    ├── reality-link.txt            annotated Path A link template
    ├── ws-cloudflare-link.txt      annotated Path B link template
    └── inbound-checklist.md        printable field-by-field checklist
```

---

## 14. Appendix — rebuild checklist

Print this. It's the whole build in one page.

```mermaid
flowchart TD
    A["1 · Buy VPS<br/>KVM · 1 Gbps · monthly · clean provider"] --> B["2 · Verify IP reachable<br/>from your ISP before configuring"]
    B --> C["3 · apt update && upgrade<br/>install curl socat"]
    C --> D["4 · Enable BBR<br/>VERIFY = bbr"]
    D --> E["5 · Reboot if kernel changed"]
    E --> F["6 · Install 3x-ui<br/>SQLite · port ≤65535 · random creds"]
    F --> G["7 · DNS: grey A → direct.<br/>orange A → cdn."]
    G --> H["8 · Cert via API token<br/>DNS-01 wildcard"]
    H --> I["9 · Inbound A: Reality :443<br/>Address BLANK · Decryption none"]
    I --> J["10 · Test Path A<br/>ss → TcpTest → client"]
    J --> K["11 · Inbound B: WS+TLS :8443<br/>SNI=cdn · ALPN http/1.1 · no flow"]
    K --> L["12 · Cloudflare SSL = Full (Strict)"]
    L --> M["13 · curl must return 400<br/>+ Sec-Websocket-Version"]
    M --> N["14 · Build client links<br/>domain not IP · path %2F-encoded"]
    N --> O["15 · Rotate all credentials"]
    O --> P["16 · Set renewal reminder"]

    style D fill:#1f6feb,color:#fff
    style I fill:#1f6feb,color:#fff
    style K fill:#8250df,color:#fff
    style M fill:#1a7f37,color:#fff
    style O fill:#cf222e,color:#fff
```

### Final state

| Component | Value |
|---|---|
| Inbound A | `vless` + `reality`, `:443`, RAW, flow `xtls-rprx-vision` |
| Inbound B | `vless` + `tls`, `:8443`, WebSocket, no flow |
| Certificate | Let's Encrypt wildcard, auto-renewing |
| Cloudflare | `cdn.` proxied · `direct.` DNS-only · Full (Strict) |
| Congestion control | BBR |
| Panel | Random port + random base path + rotated credentials |

---

## Credits & further reading

- [3x-ui](https://github.com/MHSanaei/3x-ui) — the panel used throughout
- [Xray-core](https://github.com/XTLS/Xray-core) — the proxy core
- [REALITY documentation](https://xtls.github.io/config/transports/reality.html)
- [acme.sh](https://github.com/acmesh-official/acme.sh) — ACME client for DNS-01
- [Cloudflare: origin ports](https://developers.cloudflare.com/fundamentals/reference/network-ports/)
- [Cloudflare: 1xxx errors](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/)

## License

MIT — see [LICENSE](LICENSE).

> **Disclaimer:** provided for education and lawful personal use — protecting your own traffic, testing your own infrastructure, and studying network protocols. You are responsible for complying with the laws and terms of service that apply to you.
