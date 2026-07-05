# `auth` namespace — Ory (Kratos + Hydra) SSO stack

Replaces Dex as the cluster IdP with the Ory stack, which supports **OAuth2 Dynamic
Client Registration (RFC 7591/7592)** — required so MCP clients (Phase 2) can
self-register — plus the `client_credentials` grant and JWT access tokens.

## Components

| App | Purpose | Public host | Internal only |
|-----|---------|-------------|---------------|
| `postgres` | Two CNPG Postgres clusters (`hydra`, `kratos`) | — | ✅ |
| `hydra` | OAuth2/OIDC Authorization Server + DCR (JWT access tokens) | `auth.${DOMAIN}` (public API `:4444`) | admin `:4445` never routed |
| `kratos` | Identity / GitHub social sign-in; Hydra login+consent provider | `kratos.${DOMAIN}` (public API) | admin never routed |
| `kratos-ui` | Self-service login/consent/settings screens | `login.${DOMAIN}` | — |

`hydra-maester` (bundled with the Hydra chart) reconciles `OAuth2Client` CRDs.

## Required Bitwarden Secrets Manager keys

Create these before Flux reconciles `auth` (ExternalSecrets pull them):

| Key | Notes |
|-----|-------|
| `ORY_HYDRA_DB_PASSWORD` | Hydra DB owner password |
| `ORY_KRATOS_DB_PASSWORD` | Kratos DB owner password |
| `ORY_HYDRA_SECRETS_SYSTEM` | random ≥ 32 chars |
| `ORY_HYDRA_SECRETS_COOKIE` | random ≥ 32 chars |
| `ORY_KRATOS_SECRETS_DEFAULT` | random ≥ 32 chars |
| `ORY_KRATOS_SECRETS_COOKIE` | random ≥ 32 chars |
| `ORY_KRATOS_SECRETS_CIPHER` | random **exactly** 32 chars (AES-256) |
| `ORY_KRATOS_UI_COOKIE_SECRET` | random ≥ 32 chars |
| `ORY_KRATOS_UI_CSRF_SECRET` | random ≥ 32 chars |
| `GITHUB_ORG_READ_TOKEN` | PAT with `read:org` for `celest-io` (org gate, see below) |
| `DEX_GITHUB_CLIENT_ID` / `DEX_GITHUB_CLIENT_SECRET` | **reused** existing GitHub OAuth App creds |

## Manual GitHub step

Add `https://login.${DOMAIN}/self-service/methods/oidc/callback/github` as an
authorized callback URL on the existing GitHub OAuth App (keep the Dex callback until
cutover). Same client id/secret are reused.

## ⚠️ Open items before cutover (NOT done in this PR)

This PR is **additive** — Ory runs alongside Dex, and nothing is pointed at it yet.
Complete these, verified in-cluster, before switching production auth:

1. **`celest-io` org gate — not yet enforced.** Dex restricted logins to the org
   natively; Kratos cannot do this in config alone (GitHub OIDC claims omit org
   membership; Kratos web_hook URLs aren't templated). Follow-up: deploy a small
   membership-check webhook (prebuilt image) and wire it as a `web_hook`
   (`can_interrupt: true`) on `registration.after.oidc` and `login.after.oidc`.
   The `read:org` scope is already requested. **Until this exists, any GitHub user
   can sign in.**
2. **Cut Hermes over.** In `kubernetes/apps/ai/hermes/app/helmrelease.yaml` set
   `HERMES_DASHBOARD_OIDC_ISSUER: https://auth.${DOMAIN}` and provision a
   `hermes-dashboard` client. The `OAuth2Client` CRD cannot pin a fixed `client_id`,
   so either (a) source the client id from the Maester-generated secret (place the
   `OAuth2Client` in the `ai` namespace, `dependsOn: hydra`, read `CLIENT_ID` from
   its secret), or (b) create it with a fixed id via a `hydra import oauth2-client`
   Job.
3. **Remove Dex** (`kubernetes/core/network/dex/` + its kustomization entry) once
   Hermes verifies against Ory.

## Validation status

Authored without a live cluster or `helm`/`kustomize` available — YAML validated with
`yq` only. Verify against the running cluster: chart value paths (esp. `secret.nameOverride`
key names `dsn`/`secretsSystem`/`secretsCookie` etc.), the Ory env-override names, service
names/ports (`hydra-public:4444`, `kratos-public:80`), and the `kratos-selfservice-ui-node`
image tag.
