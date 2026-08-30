// Bootstrap application for the celld fleet.
//
// It exists so the fleet has a deployment to load at boot, and so a durable
// write can be exercised end to end without deploying anything else: each
// name is its own cell with its own SQLite database, and the counter it
// returns has been through the replication path into the RustFS bucket.
//
// Replace it with `celld deploy` from a real Wrangler project whenever you
// have one; nothing here is load-bearing for the fleet itself.

export class Counter {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const count = ((await this.state.storage.get("count")) ?? 0) + 1;
    await this.state.storage.put("count", count);
    return Response.json({
      cell: new URL(request.url).searchParams.get("name") ?? "default",
      count,
    });
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/count") {
      const name = url.searchParams.get("name") ?? "default";
      return env.COUNTER.get(env.COUNTER.idFromName(name)).fetch(request);
    }
    return Response.json({
      worker: "bootstrap",
      message: "This fleet is serving its bootstrap application.",
      routes: ["/count?name=<cell>"],
    });
  },
};
