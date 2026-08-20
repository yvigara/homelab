# Buzz relay secrets. Both are 32 random bytes rendered as 64 lowercase hex
# characters, which is the shape the relay wants for either value.
#
# The relay reads them from Bitwarden through External Secrets; see
# kubernetes/apps/buzz/relay/app/externalsecret.yaml.

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
