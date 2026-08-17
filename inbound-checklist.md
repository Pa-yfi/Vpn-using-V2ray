# Inbound checklist

Print this. Tick every box before reporting a problem.

## Path A — Reality (:443)

**Basics**
- [ ] Protocol = `vless`
- [ ] **Address = BLANK** ← a domain here kills the ENTIRE Xray process
- [ ] Port = `443`

**Protocol**
- [ ] Decryption = `none` (Clear any `mlkem768x25519plus...`)
- [ ] Encryption = empty

**Stream**
- [ ] Transmission = `RAW`

**Security**
- [ ] Security = `Reality`
- [ ] Target = `www.speedtest.net:443`
- [ ] SNI = `www.speedtest.net` (same host, no port)
- [ ] uTLS = `chrome`
- [ ] Keypair generated with the button (never typed)
- [ ] Exactly ONE Short ID
- [ ] Min Client Ver: blank for Xray-core clients, `1.8.0` for sing-box
- [ ] Max Client Ver = blank

**Client**
- [ ] Flow = `xtls-rprx-vision`

**Verify**
- [ ] `ss -tlnp | grep :443` shows an xray listener
- [ ] `Test-NetConnection SERVER_IP -Port 443` → True

---

## Path B — WebSocket + TLS behind Cloudflare (:8443)

**Cloudflare**
- [ ] A record `cdn` → **SERVER_IP** (not a CF IP), **Proxied**
- [ ] A record `direct` → SERVER_IP, **DNS only**
- [ ] SSL/TLS mode = `Full` or `Full (Strict)` — never `Flexible`

**Certificate**
- [ ] `openssl x509 -in /root/cert/cert.crt -noout -subject -dates` succeeds
- [ ] `openssl rsa -in /root/cert/cert.key -check -noout` → `RSA key ok`
- [ ] `chmod 600` on the key
- [ ] `systemctl restart x-ui` after any cert change

**Basics**
- [ ] Protocol = `vless`
- [ ] **Address = BLANK**
- [ ] Port = `8443`

**Protocol**
- [ ] Decryption = `none`

**Stream**
- [ ] Transmission = `WebSocket`
- [ ] Host = `cdn.example.com`
- [ ] Path = `/xK9pQ`

**Security**
- [ ] Security = `TLS`
- [ ] SNI = `cdn.example.com` ← NOT the Reality SNI
- [ ] ALPN = `http/1.1` ONLY (remove `h2`)
- [ ] uTLS = empty
- [ ] Mode = `File Path`
- [ ] Public Key = `/root/cert/cert.crt`
- [ ] Private Key = `/root/cert/cert.key` (not swapped)

**Client**
- [ ] Flow = **empty**

**Verify**
- [ ] `ss -tlnp | grep :8443` shows a listener
- [ ] `openssl s_client -connect 127.0.0.1:8443 -servername cdn.example.com` → `Verify return code: 0 (ok)`
- [ ] `curl -v https://cdn.example.com:8443/xK9pQ` → `400 Bad Request` + `Sec-Websocket-Version: 13`

---

## Client link
- [ ] Address is the DOMAIN, not the IP
- [ ] Path is percent-encoded (`%2F...`)
- [ ] `sni` and `host` both = `cdn.example.com`
- [ ] No `flow` parameter on the WebSocket profile
- [ ] Old profile **deleted** and re-imported (editing is not enough)

---

## After it works
- [ ] Rotate panel username / password / web path / API token
- [ ] Regenerate the Reality keypair and re-export links
- [ ] Set a VPS renewal reminder (3 days early) or enable auto-renew
- [ ] Save working links somewhere safe
