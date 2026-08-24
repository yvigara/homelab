# camofox

[camofox-browser](https://github.com/jo-inc/camofox-browser) — a Node server
wrapping [Camoufox](https://camoufox.com), a Firefox fork that spoofs
fingerprints at the C++ level. It exposes a REST API that returns accessibility
snapshots with stable element refs (`e1`, `e2`, …) instead of raw HTML, which is
what makes it usable as an agent browser.

It exists here so the [Hermes](../hermes) agent can reach sites that block
Playwright and headless Chrome. Hermes talks to it at
`http://camofox.ai.svc.cluster.local:9377`.

## Wiring

| Piece | Where |
| --- | --- |
| Backend selection | `browser.cloud_provider: camofox` in `../hermes/app/resources/config.yaml` |
| Server address | `CAMOFOX_URL` in `../hermes/app/helmrelease.yaml` |
| Bearer token | `CAMOFOX_API_KEY` in both `camofox-secret` and `hermes-secret` |
| Interactive browser | noVNC at `camofox.int.<region>.<environment>.<domain>` (`traefik-private`) |

`CAMOFOX_URL` is only the address — Hermes activates the backend from the
`cloud_provider` selection, not from the env var. Camofox has no CDP endpoint,
so Hermes keeps its built-in browser tools rather than the browser-use harness,
and the `browser` toolset is enabled in `agent.disabled_toolsets`.

## Secret

Two Bitwarden Secrets Manager entries. `CAMOFOX_API_KEY` (any random string,
`openssl rand -hex 32`) lands in three places from the one value:

- `CAMOFOX_ACCESS_KEY` on the server — gates *every* route except `/health`, so
  the API is not open to anything else that can reach the pod's ClusterIP.
- `CAMOFOX_API_KEY` on the server — gates cookie import specifically.
- `CAMOFOX_API_KEY` on Hermes — the bearer token it sends. The server accepts
  the access key as a superkey on the cookie routes, so one token covers both.

`CAMOFOX_VNC_PASSWORD` is the second entry: 8 random characters, because VNC
auth only uses the first 8 (see [Interactive login](#interactive-login)).

## Storage

The PVC at `/data` holds `profiles/`, `cookies/`, `uploads/` and `traces/`.
Hermes runs with `browser.camofox.managed_persistence: true`, so sessions get a
stable user id and the server maps them onto a persistent profile directory —
sites stay logged in across restarts of either side.

The pod runs as root: Camoufox lives in `/root/.cache/camoufox` inside the image
and `/root` is `0700`, so nothing else can reach the browser binary.

## Interactive login

VNC is on, so the browser runs headed on a 1920x1080 Xvfb and is reachable at
`https://camofox.int.<region>.<environment>.<domain>` — LAN only, through
`traefik-private`, with no Cloudflare record. The display carries the live
Camoufox windows, the agent's tabs included — log into a site on one of those
tabs and the persistence plugin checkpoints the storage state under that
session's profile, so the agent stays logged in afterwards. (Hermes can also be
pinned to a fixed session with `CAMOFOX_USER_ID` / `CAMOFOX_SESSION_KEY` if a
single shared browser identity is ever wanted instead.)

The route sends the bare hostname to `/vnc.html` (an `Exact: /` match with a
`ReplaceFullPath` rewrite); everything else passes through untouched, because
noVNC's assets and the `/websockify` socket are served from the same port.

Inside the pod the chain is Camoufox → Xvfb → x11vnc (bound to loopback with
`-localhost`) → websockify → `:6080`. Only websockify is exposed, and it is
served *outside* Express, so `CAMOFOX_ACCESS_KEY` does not apply to it —
`VNC_PASSWORD` from `camofox-secret` is what gates the session. Classic VNC
auth uses an 8-byte key: only the first 8 characters of the Bitwarden value are
significant, so make it 8 random characters rather than a long string that only
looks strong.

Storage state can be exported afterwards via `GET
/sessions/:userId/storage_state` on the API port (that one *is* behind the
access key). Cookie import (`POST /sessions/:userId/cookies`, Netscape format)
remains the non-interactive path.

## Telemetry

Upstream defaults to sending anonymized crash/hang reports to a vendor endpoint
that files GitHub issues. `CAMOFOX_CRASH_REPORT_ENABLED: "false"` turns it off.
