# 05 — Troubleshooting

Every failure in this document was hit during a real build. Each entry has the **raw log**, the **root cause**, and the **fix**.

---

## The golden rule

> **Never guess. Walk the ladder.**

Each rung isolates one segment of the path. Stop at the first rung that fails; everything above it is already proven good.

```mermaid
flowchart TD
    R1["Rung 1 — Is Xray listening?<br/><code>ss -tlnp | grep -E ':443|:8443'</code>"]
    R2["Rung 2 — Is the port reachable?<br/><code>Test-NetConnection SERVER_IP -Port 443</code>"]
    R3["Rung 3 — Does TLS work locally?<br/><code>openssl s_client -connect 127.0.0.1:8443</code>"]
    R4["Rung 4 — Does the full CDN path work?<br/><code>curl -v https://cdn.example.com:8443/WS_PATH</code>"]
    R5["Rung 5 — Is the client link correct?<br/>compare every parameter"]

    R1 --> R2 --> R3 --> R4 --> R5

    R1 -. fail .-> C1["Config error →<br/>journalctl -u x-ui -n 50"]
    R2 -. fail .-> C2["Network/IP blocked →<br/>request IP change or use Path B"]
    R3 -. fail .-> C3["Certificate problem →<br/>E-06 / E-07"]
    R4 -. fail .-> C4["Cloudflare problem →<br/>E-07 / E-08"]
    R5 -. fail .-> C5["Link problem →<br/>E-09 / E-10"]

    style C2 fill:#cf222e,color:#fff
```

---

## Reading the logs

```bash
journalctl -u x-ui -f          # live
journalctl -u x-ui -n 50 --no-pager
x-ui status
```

### Startup, healthy

```
INFO - Web server running HTTP on [::]:PANEL_PORT
INFO - Sub server running HTTP on [::]:2096
INFO - XRAY: infra/conf/serial: Reading config: &{Name:bin/config.json Format:json}
WARNING - XRAY: core: Xray XX.X.XX started
INFO - xray core supports the online-stats API
```

The presence of `Xray ... started` with no following `ERROR` is what "working" looks like.

### Startup, broken

```
ERROR - XRAY: Failed to start: main: failed to load config files: [bin/config.json] >
infra/conf: failed to build inbound config with tag in-8443-tcp > ...
ERROR - Failure in running xray-core: exit status 23
```

Repeating every 2 seconds = systemd restart loop. **All inbounds are down**, not just the broken one.

---

## Noise you should ignore

| Log line | Verdict |
|---|---|
| `use of closed network connection` | Listener closed after an inbound edit. Normal. |
| `The feature WebSocket transport ... is deprecated` | Informational. WS is still correct behind a CDN. |
| `verify error:num=20:unable to get local issuer certificate` | Only with a Cloudflare Origin Certificate — its CA isn't publicly trusted. Fine in `Full` mode. |
| `REALITY: The default minimal client version is ...` | Informational **but important** — see E-09. |
| `REALITY: Changing "minClientVer" will increase the likelihood ...` | Expected once you lower the value deliberately. |

---

## E-01 · `E: Unable to locate package x-ui`

```console
root@server:~# apt install x-ui
E: Unable to locate package x-ui
```

Not in Ubuntu repos. Install from the project script:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
```

---

## E-03 · Panel restart loop, `status=1/FAILURE`

```console
● x-ui.service
     Active: activating (auto-restart) (Result: exit-code)
    Process: 905 ExecStart=/usr/local/x-ui/x-ui (code=exited, status=1/FAILURE)
```

**Cause:** panel port above 65535. The installer doesn't validate the input.

```bash
x-ui setting -port 52175
systemctl restart x-ui
journalctl -u x-ui -n 30 --no-pager
```

---

## E-04 · `no valid A records found`

```console
[...] Verifying: example.com
[...] example.com: Invalid status. Verification error details:
      no valid A records found for example.com
Issuing certificate failed, please check logs.
```

Then, confusingly:

```
⚠ SSL Certificate: Enabled and configured
```

**That success line is hardcoded and false.** Verify independently:

```bash
openssl x509 -in /path/to/cert -noout -dates
```

**Cause:** HTTP-01 requires the name to resolve to this host already.
**Fix:** create a grey-cloud A record and confirm with `dig +short host.example.com`, or use DNS-01 (no A record needed).

---

## E-05 · `unable to listen on domain address` ⚠️ CRITICAL

```console
ERROR - XRAY: Failed to start: main: failed to load config files: [bin/config.json] >
infra/conf: failed to build inbound config with tag in-8443-tcp >
infra/conf: unable to listen on domain address: cdn.example.com
ERROR - Failure in running xray-core: exit status 23
```

**Cause:** a hostname in the **Basics → Address** field. That field is a *bind address* (local IP), not the public name clients dial.

**Blast radius:** the whole Xray process refuses to start — your working Reality inbound dies too.

**Fix:** blank the field, save, restart, confirm both listeners:

```bash
systemctl restart x-ui
ss -tlnp | grep -E ':443|:8443'
```

```
LISTEN 0 4096 *:443   *:*  users:(("xray-linux-amd6",pid=6868,fd=3))
LISTEN 0 4096 *:8443  *:*  users:(("xray-linux-amd6",pid=6868,fd=6))
```

| The domain belongs in | Not in |
|---|---|
| Stream → Host | ❌ Basics → Address |
| Security → SNI | |
| Client link | |

---

## E-06 · `Could not read certificate`

```console
root@server:~# openssl x509 -in /root/cert/cert.crt -noout -subject -dates
Could not read certificate from /root/cert/cert.crt
Unable to load certificate
```

Non-zero file size but invalid PEM.

```bash
head -1 /root/cert/cert.crt    # -----BEGIN CERTIFICATE-----
tail -1 /root/cert/cert.crt    # -----END CERTIFICATE-----
head -1 /root/cert/cert.key    # -----BEGIN PRIVATE KEY-----
```

| Finding | Cause |
|---|---|
| `.crt` begins with `BEGIN PRIVATE KEY` | Files swapped |
| Missing BEGIN/END | Copy dropped a line |
| Wrapped lines | Editor reflowed the text |

**Fix:** re-paste with a quoted heredoc, never a text editor:

```bash
cat > /root/cert/cert.crt <<'EOF'
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
EOF
```

Validate, then **restart** — cert changes don't hot-reload:

```bash
openssl x509 -in /root/cert/cert.crt -noout -subject -dates
openssl rsa  -in /root/cert/cert.key -check -noout     # RSA key ok
systemctl restart x-ui
```

---

## E-07 · Cloudflare `525`

```console
< HTTP/1.1 525 <none>
< Server: cloudflare
error code: 525
```

CF reached the origin; the **CF↔origin TLS handshake** failed.

Confirm locally:

```console
root@server:~# openssl s_client -connect 127.0.0.1:8443 -servername cdn.example.com </dev/null 2>&1 | head -20
error:0A000458:SSL routines:ssl3_read_bytes:tlsv1 unrecognized name
CONNECTED(00000003)
no peer certificate available
SSL handshake has read 7 bytes and written 318 bytes
New, (NONE), Cipher is (NONE)
```

`unrecognized name` + `no peer certificate` = Xray has no usable cert for that SNI.

**Checklist**

1. Cert and key both parse (E-06)
2. Panel paths not swapped; mode = **File Path**
3. Panel SNI = `cdn.example.com` (not the Reality SNI)
4. `systemctl restart x-ui` after any change
5. Cloudflare mode = `Full` or `Full (Strict)`

**Healthy:**

```console
issuer=C = US, O = Let's Encrypt, CN = ...
New, TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256
Verify return code: 0 (ok)
```

---

## E-08 · Cloudflare `Error 1000 — DNS points to prohibited IP`

**Cause:** the A record's content is a Cloudflare IP, not your origin.

```console
PS> nslookup cdn.example.com
Addresses:  172.64.80.1        ← CF anycast. CORRECT to see here.
                                 NEVER paste this into the dashboard.
```

**Fix:** dashboard `Content` = `SERVER_IP`, proxy status **Proxied**. Both statements below are simultaneously true:

| Where | Value |
|---|---|
| Cloudflare dashboard record | your VPS IP |
| Public DNS resolution | Cloudflare anycast IP |

---

## E-09 · Silent timeout — Reality's hardest failure

**Symptom:** `Connecting… / Timeout`, `0 B` traffic, **no server log entries at all**.

By design, Reality forwards failed authentication to the real destination site instead of returning an error. No error, no log, no signal.

```mermaid
flowchart LR
    C["Client"] -->|"bad auth"| S["Your server"]
    S -->|"transparent forward"| R["www.speedtest.net"]
    R -->|"real TLS response"| C
    S -.->|"❌ nothing logged"| L[("Log")]

    style L fill:#6e7781,color:#fff
```

**Ranked causes**

| # | Cause | Fix |
|---|---|---|
| 1 | Default `minClientVer` rejects non-Xray clients | Set `1.8.0`, or use an Xray-core client |
| 2 | `Decryption` = `mlkem768x25519plus...` | **Clear** → `none` |
| 3 | Stale client profile after an inbound edit | **Delete** and re-import — editing isn't enough |
| 4 | Typo in `pbk` / `sid` | Copy the panel's link or QR |
| 5 | Wrong `flow` | Reality → `xtls-rprx-vision`; WS → empty |
| 6 | Client core mismatch | Cross-test with a different client |

**The `minClientVer` warning at startup:**

```
[Warning] infra/conf: REALITY: The default minimal client version is Xray-core vXX.X.XX,
other clients may be refused to connect
```

Trade-off: lowering it admits older clients whose TLS fingerprints differ from a real browser, making them somewhat easier for DPI to distinguish. Prefer upgrading the client.

---

## E-10 · Link uses the IP instead of the domain

**Symptom:** `curl` returns a healthy `400 Bad Request`, but the client still hangs.

**Cause:** with **Address** blank (correct), 3x-ui writes `SERVER_IP` into generated links. The client bypasses Cloudflare, connects straight to the origin, and — with a CF Origin Certificate — hits an untrusted cert. Silent failure.

**Fix:** edit the link's host, or set **External Proxy** = `cdn.example.com:8443` in the inbound.

**Correct Path B link parameters**

```
@cdn.example.com:8443
type=ws
security=tls
encryption=none
sni=cdn.example.com
host=cdn.example.com
path=%2FxK9pQ          ← percent-encoded
fp=chrome
alpn=http%2F1.1
(no flow)
```

---

## Success signals — what "working" looks like

| Check | Healthy output |
|---|---|
| `ss -tlnp \| grep :443` | `LISTEN ... xray-linux-amd6` |
| `Test-NetConnection` | `TcpTestSucceeded : True` |
| `openssl s_client` | `Verify return code: 0 (ok)` + real issuer |
| `curl https://cdn...:8443/WS_PATH` | `400 Bad Request` + `Sec-Websocket-Version: 13` |
| `sysctl ...congestion_control` | `bbr` |
| Client | Traffic counter climbing above `0 B` |

> 🎯 `400 Bad Request` from your own origin is **the** milestone. It proves client → Cloudflare → TLS → Xray all work. Anything still broken after that lives in the client link.
