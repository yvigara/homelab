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

`CAMOFOX_URL` is only the address — Hermes activates the backend from the
`cloud_provider` selection, not from the env var. Camofox has no CDP endpoint,
so Hermes keeps its built-in browser tools rather than the browser-use harness,
and the `browser` toolset is enabled in `agent.disabled_toolsets`.

## Secret

One Bitwarden Secrets Manager entry, `CAMOFOX_API_KEY` (any random string,
`openssl rand -hex 32`). It lands in three places from the one value:

- `CAMOFOX_ACCESS_KEY` on the server — gates *every* route except `/health`, so
  the API is not open to anything else that can reach the pod's ClusterIP.
- `CAMOFOX_API_KEY` on the server — gates cookie import specifically.
- `CAMOFOX_API_KEY` on Hermes — the bearer token it sends. The server accepts
  the access key as a superkey on the cookie routes, so one token covers both.

## Storage

The PVC at `/data` holds `profiles/`, `cookies/`, `uploads/` and `traces/`.
Hermes runs with `browser.camofox.managed_persistence: true`, so sessions get a
stable user id and the server maps them onto a persistent profile directory —
sites stay logged in across restarts of either side.

The pod runs as root: Camoufox lives in `/root/.cache/camoufox` inside the image
and `/root` is `0700`, so nothing else can reach the browser binary.

## Interactive login

For sites that need a hands-on login, the image can run headed behind noVNC
(`ENABLE_VNC=1`, `VNC_BIND=0.0.0.0`, `VNC_PASSWORD`, port 6080). That is off
here; turning it on means adding those env vars, a second service port and a
route on `traefik-private`. Cookie import (`POST /sessions/:userId/cookies`,
Netscape format) covers the same need without exposing a desktop.

## Telemetry

Upstream defaults to sending anonymized crash/hang reports to a vendor endpoint
that files GitHub issues. `CAMOFOX_CRASH_REPORT_ENABLED: "false"` turns it off.
