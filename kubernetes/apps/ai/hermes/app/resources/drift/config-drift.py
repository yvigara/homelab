#!/usr/bin/env python3
"""config-drift — detect divergence between live Hermes config and the GitOps source of truth.

WHY THIS EXISTS
    /opt/data/config.yaml and /opt/data/profiles/*/config.yaml are installed wholesale
    by init.sh / profiles-init.sh on EVERY pod start. Any key not present in the homelab
    repo is silently dropped at the next restart. That happened to `kanban-card` on
    2026-09-25 and nothing reported it for ~90 minutes.

WHAT IT COMPARES
    live  /opt/data/config.yaml                  vs  git resources/config.yaml
    live  /opt/data/profiles/<p>/config.yaml     vs  git resources/profiles/<p>/config.yaml

THE TRAP THIS AVOIDS
    A naive diff reports constant noise, because Hermes ADDS keys to the live file at
    startup that the repo never defines (observed: `connections` in platform_toolsets,
    `multiplex_profiles: true`) and bumps `_config_version`. Those are not drift — they
    are added-after-install and will be recreated next boot.

    So the check is key-oriented, not text-oriented:
      * LOST   — a key path the repo defines but live no longer has  => REAL DRIFT (it will
                 not survive; this is what happened to kanban-card)
      * CHANGED— a leaf the repo defines but live holds a different value => REAL DRIFT
      * ADDED  — live has a key the repo lacks => informational only (normally Hermes')
      * _config_version is ignored entirely (Hermes-managed).

EXIT CODES
    0 = no drift   1 = drift found   2 = could not determine (error)

Usage:
    config-drift.py                # human-readable report
    config-drift.py --quiet        # print ONLY on drift (cron-friendly)
    config-drift.py --json         # machine-readable
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

REPO = Path("/opt/data/projects/yvigara/homelab")
REPO_SUBDIR = "kubernetes/apps/ai/hermes/app/resources"
DATA = Path(os.environ.get("HERMES_HOME", "/opt/data"))

# Hermes-managed keys that legitimately differ from the repo. Ignored everywhere.
IGNORED_LEAVES = {"_config_version"}


# --------------------------------------------------------------------------- yaml
def _load_yaml(text: str):
    """Parse YAML, tolerating the `hermes` venv being the only interpreter with PyYAML."""
    try:
        import yaml  # type: ignore
    except ImportError:  # re-exec under the venv interpreter that ships PyYAML
        venv = Path("/opt/hermes/.venv/bin/python3")
        if venv.is_file():
            os.execv(str(venv), [str(venv), __file__, *sys.argv[1:]])
        raise
    return yaml.safe_load(text)


def flatten(node, prefix: str = ""):
    """Yield (path, scalar) for every leaf.

    Lists are yielded as (path, json) pairs AND, when every element is a scalar, each
    element is also yielded as ``path[]`` -> value. That element view is what lets the
    comparison tell "Hermes appended an element inside a repo-defined list" (benign)
    apart from "an element the repo requires is gone" (real drift) — comparing the
    serialized whole list cannot, and reports permanent false positives.
    """
    if isinstance(node, dict):
        for key, value in node.items():
            if key in IGNORED_LEAVES:
                continue
            yield from flatten(value, f"{prefix}.{key}" if prefix else str(key))
    elif isinstance(node, list):
        yield prefix, json.dumps(node, sort_keys=True)
        if all(not isinstance(x, (dict, list)) for x in node):
            for item in node:
                yield f"{prefix}[]", item
    else:
        yield prefix, node


# --------------------------------------------------------------------------- git
def git_show(path: str) -> str | None:
    """File contents at origin/main, or None if absent from the repo."""
    try:
        result = subprocess.run(
            ["git", "-C", str(REPO), "show", f"origin/main:{path}"],
            capture_output=True, text=True, timeout=60,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    return result.stdout if result.returncode == 0 else None


def git_refresh() -> bool:
    """Best-effort fetch so origin/main is current. A failure is non-fatal:
    we still compare against the last-known origin/main rather than skipping the check."""
    try:
        result = subprocess.run(
            ["git", "-C", str(REPO), "fetch", "origin", "main", "--quiet"],
            capture_output=True, text=True, timeout=120,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


# --------------------------------------------------------------------------- compare
def compare_one(label: str, live_path: Path, repo_rel: str) -> dict:
    """Return a result dict for one config file.

    Drift = something the REPO DEFINES is missing or different live. That is the thing a
    restart reverts. Keys live has and the repo lacks (``added``) are informational:
    Hermes injects its own defaults at startup and they are recreated every boot.
    """
    out = {"label": label, "live": str(live_path), "repo": repo_rel,
           "lost": [], "changed": [], "added": [], "status": "ok"}
    text = git_show(repo_rel)
    if text is None:
        out["status"] = "repo-file-missing"
        return out
    if not live_path.is_file():
        out["status"] = "live-file-missing"
        return out

    repo_leaves = list(flatten(_load_yaml(text)))
    live_leaves = list(flatten(_load_yaml(live_path.read_text())))

    # Element view (``key[]``) is used for membership; the whole-list view is dropped
    # from the comparison so an appended element does not read as a changed list.
    desired = {p: v for p, v in repo_leaves if not p.endswith("]")}
    actual = {p: v for p, v in live_leaves if not p.endswith("]")}
    whole_lists = {p for p, _ in repo_leaves if not p.endswith("]") and any(
        p == q for q, _ in repo_leaves if not q.endswith("]"))}
    desired = {p: v for p, v in desired.items() if p not in whole_lists}
    actual = {p: v for p, v in actual.items() if p not in whole_lists}

    repo_elems: dict[str, set] = {}
    live_elems: dict[str, set] = {}
    for path, value in repo_leaves:
        if path.endswith("[]"):
            repo_elems.setdefault(path[:-2], set()).add(value)
    for path, value in live_leaves:
        if path.endswith("[]"):
            live_elems.setdefault(path[:-2], set()).add(value)

    # A repo-defined list whose elements vanished = real drift.
    for key, wanted in repo_elems.items():
        missing = wanted - live_elems.get(key, set())
        if missing:
            out["lost"].append(
                {"path": f"{key}[]", "repo_value": sorted(missing),
                 "live_value": sorted(live_elems.get(key, set()))})

    for path, want in desired.items():
        if path not in actual:
            out["lost"].append({"path": path, "repo_value": want})
        elif actual[path] != want:
            out["changed"].append(
                {"path": path, "repo_value": want, "live_value": actual[path]})
    for path, have in actual.items():
        if path not in desired:
            out["added"].append({"path": path, "live_value": have})

    if out["lost"] or out["changed"]:
        out["status"] = "DRIFT"
    return out


def collect() -> list[dict]:
    results = [compare_one("default", DATA / "config.yaml", f"{REPO_SUBDIR}/config.yaml")]
    profiles_dir = DATA / "profiles"
    if profiles_dir.is_dir():
        for prof in sorted(p for p in profiles_dir.iterdir() if p.is_dir()):
            cfg = prof / "config.yaml"
            if not cfg.is_file():
                continue
            results.append(compare_one(
                prof.name, cfg, f"{REPO_SUBDIR}/profiles/{prof.name}/config.yaml"))
    return results


# --------------------------------------------------------------------------- render
def render(results: list[dict]) -> tuple[int, str]:
    drifts = [r for r in results if r["status"] == "DRIFT"]
    problems = [r for r in results if r["status"] not in ("ok", "DRIFT")]
    lines: list[str] = []

    if drifts:
        lines.append(":rotating_light: *Hermes config drift detected*")
        lines.append("")
        lines.append("Live config no longer matches the GitOps source of truth. "
                     "A pod restart will revert the live values below.")
        lines.append("")
        for r in drifts:
            lines.append(f"*{r['label']}*  (`{r['repo'].split('/')[-2:] and r['repo']}`)")
            for item in r["lost"]:
                lines.append(f"  • LOST    `{item['path']}` — in git, absent live "
                             f"(value: `{item['repo_value']}`)")
            for item in r["changed"]:
                lines.append(f"  • CHANGED `{item['path']}` — git `{item['repo_value']}` "
                             f"vs live `{item['live_value']}`")
            lines.append("")
        lines.append("Fix: change the homelab repo and raise a PR. "
                     "See `kubernetes/apps/ai/hermes/app/resources/`.")

    if problems:
        lines.append("")
        lines.append(":warning: could not evaluate:")
        for r in problems:
            lines.append(f"  • {r['label']}: {r['status']}")

    exit_code = 1 if (drifts or problems) else 0
    return exit_code, "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--quiet", action="store_true", help="print only when there is drift")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-fetch", action="store_true", help="skip the git fetch")
    args = ap.parse_args()

    if not REPO.is_dir():
        msg = f"config-drift: repo not found at {REPO}"
        print(msg, file=sys.stderr)
        return 2
    fetched = True if args.no_fetch else git_refresh()

    results = collect()
    if args.json:
        print(json.dumps({"fetched": fetched, "results": results}, indent=2))
        return 1 if any(r["status"] != "ok" for r in results) else 0

    code, report = render(results)
    if report:
        print(report)
    elif not args.quiet:
        n = len(results)
        stale = "" if fetched else "  (warning: git fetch failed — compared against last-known origin/main)"
        print(f"config-drift: no drift — {n} config file(s) match origin/main.{stale}")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
