/**
 * Post-login Action: restrict sign-in to members of a GitHub organization.
 *
 * Replaces the behaviour of Dex's native `orgs:` connector option. Runs after a
 * GitHub social login and denies access unless the user is an active member of the
 * organization named in the `GITHUB_ORG` action secret. Uses the GitHub access
 * token captured during this login (node22 provides a global `fetch`).
 *
 * @param {Event} event
 * @param {PostLoginAPI} api
 */
exports.onExecutePostLogin = async (event, api) => {
  // Only gate logins that came through the GitHub connection.
  if (event.connection.strategy !== "github") {
    return;
  }

  const org = event.secrets.GITHUB_ORG;
  const identity = (event.user.identities || []).find((i) => i.provider === "github");
  const token = identity && identity.access_token;
  const login = event.user.nickname; // GitHub username for the github strategy

  if (!org || !token || !login) {
    api.access.deny("Unable to verify GitHub organization membership.");
    return;
  }

  const resp = await fetch(
    "https://api.github.com/orgs/" + org + "/memberships/" + login,
    {
      headers: {
        Authorization: "Bearer " + token,
        Accept: "application/vnd.github+json",
        "User-Agent": "auth0-org-gate",
      },
    }
  );

  if (resp.status !== 200) {
    api.access.deny("You must be a member of the " + org + " GitHub organization.");
    return;
  }

  const body = await resp.json();
  if (body.state !== "active") {
    api.access.deny("Your " + org + " GitHub organization membership is not active.");
  }
};
