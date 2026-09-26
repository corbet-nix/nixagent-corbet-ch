# SPDX-License-Identifier: MIT OR Apache-2.0
"""API-key tool connections and company secrets, kept equal to the reconciler's environment."""
import os

from api import call, change, fingerprint, items, say


# ── connections and secrets ──────────────────────────────────────────────────────────────────
def reconcile_connections(key, company, spec):
    connections = spec.get("connections", {})
    existing = {c["name"]: c for c in items(call("GET", f"/companies/{company}/tools/connections"), "connections")
                if c.get("status") != "archived" and c.get("transport") != "runtime_auth"}
    stored = None
    for want in connections.values():
        secret = os.environ.get(want["credentialEnv"])
        if not secret:
            say(key, f"connection {want['name']}: ${want['credentialEnv']} is not set; skipped")
            continue
        if want["name"] in existing:
            # The connection reads its credential secret at version "latest", so rotating that
            # secret is the whole rotation; an HMAC in its providerMetadata detects change.
            ref = next((r for r in existing[want["name"]].get("credentialSecretRefs") or [] if r.get("configPath") == want["credentialField"]), None)
            if ref is None:
                continue
            if stored is None:
                stored = {x["id"]: x for x in items(call("GET", f"/companies/{company}/secrets"), "secrets")}
            meta = (stored.get(ref["secretId"]) or {}).get("providerMetadata") or {}
            mark = fingerprint(secret)
            if meta.get("nixagentHmac") != mark:
                def rotate(ref=ref, secret=secret, meta=meta, mark=mark):
                    call("POST", f"/secrets/{ref['secretId']}/rotate", {"value": secret})
                    call("PATCH", f"/secrets/{ref['secretId']}", {"providerMetadata": {**meta, "nixagentHmac": mark}})
                change(key, f"rotate the credential of {want['name']}", rotate)
            continue

        def connect(want=want, secret=secret):
            result = call("POST", f"/companies/{company}/tools/apps/connect", {
                "galleryKey": want["gallery"], "connectionMethodKey": want["method"], "name": want["name"],
                "credentialValues": {want["credentialField"]: secret},
            })
            call("POST", f"/companies/{company}/tools/apps/{result['connectionId']}/finish", {
                "enabledCatalogEntryIds": [e["id"] for e in result.get("catalog", [])], "askFirstCatalogEntryIds": [], "access": "all_agents",
            })
        change(key, f"connect {want['name']}", connect)
    for name in sorted(existing.keys() - {c["name"] for c in connections.values()}):
        say(key, f"connection {name} exists but is not declared (left alone)")


def reconcile_secrets(key, company, spec):
    secrets = spec.get("secrets", {})
    if not secrets:
        return
    existing = {s["name"]: s for s in items(call("GET", f"/companies/{company}/secrets"), "secrets")}
    for name, want in sorted(secrets.items()):
        value = os.environ.get(want["env"])
        if not value:
            say(key, f"secret {name}: ${want['env']} is not set; skipped")
            continue
        meta = {"nixagentHmac": fingerprint(value), "nixagentEnv": want["env"]}
        have = existing.get(name)
        if have is None:
            change(key, f"create secret {name}", lambda name=name, want=want, value=value, meta=meta: call("POST", f"/companies/{company}/secrets", {
                "name": name, "value": value, "description": want["description"], "providerMetadata": meta}))
        elif (have.get("providerMetadata") or {}).get("nixagentHmac") != meta["nixagentHmac"]:
            def rotate(have=have, value=value, want=want, meta=meta):
                call("POST", f"/secrets/{have['id']}/rotate", {"value": value})
                call("PATCH", f"/secrets/{have['id']}", {"description": want["description"], "providerMetadata": meta})
            change(key, f"rotate secret {name}", rotate)


