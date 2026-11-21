# beads

`bd serve` (HTTP API for [beads](https://github.com/gastownhall/beads)) backed by
the in-cluster `dolt-sql` server.

```
client -> Cloudflare Access -> cloudflared (access.required) -> traefik-public
       -> HTTPRoute beads.${DOMAIN} -> Service beads:8742 (bd serve, bearer token)
       -> dolt-sql:3306 (cluster-internal only)
```

- Image: `ghcr.io/yvigara/bd-serve` (`images/bd-serve`): bd plus git. `bd serve`
  needs a git repository root; the container runs `git init` in its emptyDir workspace.
- bd version must be the same or older than every bd client that touches the
  database: bd refuses databases migrated by a newer schema.
- Two layers of auth: Cloudflare Access at the edge (hostname added to the mcp
  Access application) and a bearer token from Bitwarden key `BEADS_SERVE_TOKEN`
  (`Authorization: Bearer <token>`). `/healthz` is the only unauthenticated path.
- `POST /v0/beads/issues:sweep` (permanent delete of closed beads) is blocked at
  the HTTPRoute.
- `dolt-sql:3306` has no route and no LoadBalancer.
- Backups: none yet. The PVC is the only copy.
