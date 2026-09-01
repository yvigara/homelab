/**
 * Post-login Action: restrict sign-in to members of a Google Workspace domain.
 *
 * Runs after a Google social login and denies access unless Google reports the
 * account as hosted by the Workspace named in the `WORKSPACE_DOMAIN` secret.
 *
 * The check is on Google's `hd` (hosted domain) claim, NOT on the email address.
 * A consumer Google account can be registered against any email address, so
 * `user@example.com` with `email_verified: true` does not prove Workspace
 * membership -- only `hd` does, and Google omits it for consumer accounts.
 *
 * Uses the Google access token captured during this login (node22 provides a
 * global `fetch`).
 *
 * @param {Event} event
 * @param {PostLoginAPI} api
 */
exports.onExecutePostLogin = async (event, api) => {
  // Only gate logins that came through the Google connection.
  if (event.connection.strategy !== "google-oauth2") {
    return;
  }

  const domain = event.secrets.WORKSPACE_DOMAIN;
  const identity = (event.user.identities || []).find((i) => i.provider === "google-oauth2");
  const token = identity && identity.access_token;

  if (!domain || !token) {
    api.access.deny("Unable to verify Google Workspace membership.");
    return;
  }

  const resp = await fetch("https://openidconnect.googleapis.com/v1/userinfo", {
    headers: {
      Authorization: "Bearer " + token,
      "User-Agent": "auth0-workspace-gate",
    },
  });

  if (resp.status !== 200) {
    api.access.deny("Unable to verify Google Workspace membership.");
    return;
  }

  const profile = await resp.json();
  if (profile.hd !== domain) {
    api.access.deny("You must sign in with a " + domain + " Google Workspace account.");
  }
};
