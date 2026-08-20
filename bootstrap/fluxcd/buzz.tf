# Buzz relay secrets. Both are 32 random bytes rendered as 64 lowercase hex
# characters, which is the shape the relay wants for either value.
#
# The relay reads them from Bitwarden through External Secrets; see
# kubernetes/apps/buzz/relay/app/externalsecret.yaml.

# The relay's own Nostr identity. Federation peers and every event the relay
# has ever signed are bound to it, so this value is generated exactly once and
# then left alone: rotating it does not re-key the relay, it creates a
# different relay. prevent_destroy is the guard against losing it to a stray
# destroy or replace — remove the block deliberately if the identity really is
# meant to change.
#
# A secp256k1 secret key must fall in [1, n-1]. Uniform 32-byte draws land
# outside that range with probability on the order of 2^-128, so the generator
# does not screen for it.
resource "random_bytes" "buzz_relay_private_key" {
  length = 32

  lifecycle {
    prevent_destroy = true
  }
}

resource "bitwarden-secrets_secret" "buzz_relay_private_key" {
  key        = "BUZZ_RELAY_PRIVATE_KEY"
  value      = random_bytes.buzz_relay_private_key.hex
  note       = "Buzz relay Nostr identity (64 hex) — never rotate, back up"
  project_id = var.bw_project_id
}

# Signs the relay's git hook callbacks. Required once the relay runs more than
# one replica, and unlike the identity key it can be rotated freely as long as
# every replica ends up with the same value.
resource "random_bytes" "buzz_git_hook_hmac_secret" {
  length = 32
}

resource "bitwarden-secrets_secret" "buzz_git_hook_hmac_secret" {
  key        = "BUZZ_GIT_HOOK_HMAC_SECRET"
  value      = random_bytes.buzz_git_hook_hmac_secret.hex
  note       = "Buzz relay git hook HMAC secret (64 hex)"
  project_id = var.bw_project_id
}
