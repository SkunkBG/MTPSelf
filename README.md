# MTPSelf · telemt edition

Self-hosted **Telegram MTProto proxy** on [telemt](https://github.com/telemt/telemt) (Rust + Tokio).
Stronger masking than classic MTProxy: for any non-Telegram connection telemt does a **transparent
TCP-splice to a real `tls_domain`** (real certificate, real responses, real entropy) and emulates the
target's TLS record lengths. Paste-in into Telegram, no client app. Ubuntu 24.04 / Debian 12+.

## Reality check (read first)

Russia's TSPU escalated in May 2026 from JA3 fingerprinting to **statistical / behavioural traffic
analysis** (packet-size distribution, inter-packet timing, connection concentration) and partial
ASN-level blocking. The killer signatures (fixed ClientHello padding, even timings, ALPN-vs-protocol
mismatch) are produced by the **stock Telegram client**, not the server — telemt's full answer to those
is its `tdlib-obf` *client* fork, which is again an app.

So, honestly:
- On **regional / wired ISPs** a telemt paste-in proxy may well work (those were the survivors in field tests).
- On **federal mobile (MTS, YOTA, etc.)** with the May statistical DPI, even this can fail — the stock client gives you away.
- telemt is the strongest **server-side** MTProto option; it is not a guarantee against behavioural DPI.

If your network kills it too, the only remaining routes are telemt's `tdlib-obf` client or a universal
tunnel (AmneziaWG / Hysteria2 / NaiveProxy / VLESS+Reality) — all of which require a client app.

## Install

```bash
curl -fsSLo /tmp/install.sh https://raw.githubusercontent.com/SkunkBG/MTPSelf/main/install.sh
sudo TLS_DOMAIN=www.microsoft.com bash /tmp/install.sh
```

Env: `TLS_DOMAIN` (real HTTPS site to masquerade as / splice to, TLS 1.3, reachable from the server),
`MTP_TAG` (image tag, default `latest`; pin e.g. `3.3.28`), `PROXY_PORT` (default 443).
Without `TLS_DOMAIN` the installer asks interactively.

Pick a `tls_domain` that is a real, reachable, innocuous HTTPS site. For RU networks an "approved" /
common SNI tends to attract less attention. Changing it later invalidates previously issued links.

## Manage

```bash
sudo mtpself
```

Status · links · logs · restart · update telemt · change `tls_domain` · rotate secret · metrics · uninstall.

## Connect a client

Run `sudo mtpself` → *Links*, or read the `tg://proxy?…` line telemt prints in its logs:

```bash
docker compose -f /opt/telemt/docker-compose.yml logs telemt | grep -i proxy
```

In Telegram: **Settings → Data and Storage → Proxy → Add Proxy → MTProto**, server = your IP,
port `443`, secret = the `ee…` value. Works on all platforms incl. old Telegram Desktop (Win7).

## Verify

```bash
docker compose -f /opt/telemt/docker-compose.yml ps          # telemt healthy/Up
docker logs telemt --tail 30                                 # startup + links
# masking check (telemt splices to the real tls_domain):
curl -sI --resolve <tls_domain>:443:<server_ip> https://<tls_domain>/ | head -3
```

A connecting client increments connection counters on `127.0.0.1:9090/metrics`.

## How masking works

- Client **with** the secret → telemt proxies MTProto to Telegram (via middle-proxy).
- Client/probe **without** the secret → telemt transparently TCP-splices the TLS session to the real
  `tls_domain` server: valid certificate chain, genuine responses, matching entropy. No fake certs, no MITM.

This is why active probing sees a legitimate HTTPS site rather than a "proxy".

## Update

```bash
sudo mtpself        # → Update telemt
# or:
docker compose -f /opt/telemt/docker-compose.yml pull
docker compose -f /opt/telemt/docker-compose.yml up -d
```

`config.toml` (secret + tls_domain) persists. Pin `MTP_TAG` to a release for reproducibility.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `mtproto: недоступен` on federal mobile, works on wired/regional | The May statistical DPI on the stock client — see "Reality check". Not fixable server-side. |
| Proxy down everywhere incl. mobile, but `curl` on server reaches Telegram DCs | Likely DPI; confirm with OONI Probe / another network. Server is fine. |
| `Too many open files` | Raised via `ulimits` in compose; for systemd hosts also raise `LimitNOFILE`. |
| Container unhealthy | `docker logs telemt`; check `config.toml` syntax and that `tls_domain` is reachable from the server. |

## License

MIT — see [LICENSE](LICENSE).

## Credits

Powered by [telemt](https://github.com/telemt/telemt). For lawful personal use.
Threat-landscape context: Teplitsa "Разбор #9" (te-st.org), May–June 2026.
