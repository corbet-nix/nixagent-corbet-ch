# SPDX-License-Identifier: MIT OR Apache-2.0
"""nixagent.paperclip reconciler: keeps a Paperclip instance matching its Nix declaration.

Runs in the pod's reconciler sidecar every few minutes against the local API with a board key.
The desired state is the JSON the module renders (DESIRED, a mounted file). What is declared is
reconciled; what exists but is not declared is only reported, so agents may still hire and the
board may still experiment, and the declaration catches up by a human decision.

In mode "report" nothing is written: every intended change is printed with "would". In mode
"enforce" the changes are applied. Every pass is idempotent.

Reconciled per declared company:
  * the company's name, description and hire-approval setting;
  * its skill library: exactly the shared library's skills (the files are a bind mount of the
    library; this only keeps Paperclip's listing current);
  * its agents: created through a hire request that the board key approves, then kept to the
    declared title, role, manager, adapter settings, permissions, heartbeat, Paperclip skills
    and instructions (AGENTS.md);
  * its API-key tool connections: created when missing, with the credential taken from the
    environment variable the declaration names.
Never done: deleting anything but library entries whose skill directory is gone, or touching
tasks, runs and history.
"""
import json
import os
import sys
import urllib.error
import urllib.request

DESIRED = json.load(open(os.environ["NIXAGENT_PAPERCLIP_DESIRED"]))
API = DESIRED["api"]
HEADERS = {
    "Host": DESIRED["host"],
    "Authorization": "Bearer " + os.environ["PAPERCLIP_BOARD_TOKEN"],
    "Content-Type": "application/json",
}
ENFORCE = DESIRED["mode"] == "enforce"


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers=HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=180) as res:
            raw = res.read()
    except urllib.error.HTTPError as err:
        raise RuntimeError(f"{method} {path}: HTTP {err.code} {err.read()[:300]!r}") from None
    return json.loads(raw) if raw else None


def say(company, message):
    print(f"[{company}] {message}", flush=True)


def change(company, message, action):
    """Apply `action` in enforce mode; in report mode only say what would happen."""
    if ENFORCE:
        action()
        say(company, message)
    else:
        say(company, "would " + message)


def subset_differs(declared, current):
    return {k: v for k, v in declared.items() if (current or {}).get(k) != v}


def reconcile_company_settings(key, spec):
    current = call("GET", f"/companies/{spec['id']}")
    patch = subset_differs(
        {k: spec[k] for k in ("name", "description", "requireBoardApprovalForNewAgents") if spec.get(k) is not None},
        current,
    )
    if patch:
        change(key, f"update company settings {sorted(patch)}",
               lambda: call("PATCH", f"/companies/{spec['id']}", patch))
    if spec.get("issuePrefix") and current.get("issuePrefix") != spec["issuePrefix"]:
        say(key, f"issue prefix is {current.get('issuePrefix')}, declared {spec['issuePrefix']} "
                 "(the API cannot change it; set it in the database)")


def reconcile_skills(key, spec):
    library = DESIRED["skills"]["library"]
    prefix = f"{DESIRED['skills']['root']}/{spec['id']}/"
    shared = {
        d for d in os.listdir(library)
        if not d.startswith("__") and os.path.isfile(os.path.join(library, d, "SKILL.md"))
    }
    listed = {}
    for skill in call("GET", f"/companies/{spec['id']}/skills"):
        locator = skill.get("sourceLocator") or ""
        if locator.startswith(prefix):
            listed[locator[len(prefix):]] = skill["id"]
    for name in sorted(shared - listed.keys()):
        change(key, f"import skill {name}",
               lambda name=name: call("POST", f"/companies/{spec['id']}/skills/import", {"source": prefix + name}))
    for name in sorted(listed.keys() - shared):
        change(key, f"remove skill {name} (its directory is gone)",
               lambda name=name: call("DELETE", f"/companies/{spec['id']}/skills/{listed[name]}"))


def ordered_agents(agents):
    """Managers before their reports, so a new report can name its manager's id."""
    done, order = set(), []

    def visit(key, trail=()):
        if key in done:
            return
        if key in trail:
            raise RuntimeError(f"reportsTo cycle through {key}")
        boss = agents[key].get("reportsTo")
        if boss:
            visit(boss, trail + (key,))
        done.add(key)
        order.append(key)

    for key in sorted(agents):
        visit(key)
    return order


def reconcile_agents(key, spec):
    company = spec["id"]
    agents = spec.get("agents", {})
    existing = {a["name"]: a for a in call("GET", f"/companies/{company}/agents")}
    ids = {}
    for agent_key in ordered_agents(agents):
        want = agents[agent_key]
        boss = want.get("reportsTo")
        boss_id = ids.get(boss) if boss else None
        if boss and not boss_id:
            say(key, f"agent {want['name']}: manager {boss} does not exist yet; skipped this pass")
            continue
        have = existing.get(want["name"])
        if have is None:
            payload = {
                "name": want["name"], "title": want.get("title"), "role": want["role"],
                "adapterType": want["adapterType"], "adapterConfig": want["adapterConfig"],
                "desiredSkills": want["desiredSkills"], "permissions": want["permissions"],
                "runtimeConfig": {"heartbeat": want["heartbeat"]},
                "instructionsBundle": {"entryFile": "AGENTS.md", "files": {"AGENTS.md": want["instructions"]}},
            }
            if boss_id:
                payload["reportsTo"] = boss_id

            def hire(payload=payload):
                result = call("POST", f"/companies/{company}/agent-hires", payload)
                approval = (result or {}).get("approval") or {}
                if approval.get("id"):
                    call("POST", f"/approvals/{approval['id']}/approve",
                         {"decisionNote": "Declared in nixagent.paperclip; approved by its reconciler."})
                ids[agent_key] = (result or {}).get("agent", {}).get("id")
            change(key, f"hire agent {want['name']} ({want['adapterType']})", hire)
            continue
        agent_id = have["id"]
        ids[agent_key] = agent_id
        patch = subset_differs({"title": want.get("title"), "role": want["role"]}, have)
        if (have.get("reportsTo") or None) != boss_id:
            patch["reportsTo"] = boss_id
        config_patch = subset_differs(want["adapterConfig"], have.get("adapterConfig"))
        if config_patch:
            patch["adapterConfig"] = config_patch
        heartbeat = (have.get("runtimeConfig") or {}).get("heartbeat") or {}
        if subset_differs(want["heartbeat"], heartbeat):
            patch["runtimeConfig"] = {"heartbeat": {**heartbeat, **want["heartbeat"]}}
        if patch:
            change(key, f"update agent {want['name']} {sorted(patch)}",
                   lambda agent_id=agent_id, patch=patch: call("PATCH", f"/agents/{agent_id}", patch))
        if subset_differs(want["permissions"], have.get("permissions")):
            change(key, f"update agent {want['name']} permissions",
                   lambda agent_id=agent_id: call("PATCH", f"/agents/{agent_id}/permissions", want["permissions"]))
        skills = ((have.get("adapterConfig") or {}).get("paperclipSkillSync") or {}).get("desiredSkills") or []
        if sorted(skills) != sorted(want["desiredSkills"]):
            change(key, f"set agent {want['name']} Paperclip skills",
                   lambda agent_id=agent_id: call("POST", f"/agents/{agent_id}/skills/sync",
                                                  {"mode": "replace", "desiredSkills": want["desiredSkills"]}))
        current = call("GET", f"/agents/{agent_id}/instructions-bundle/file?path=AGENTS.md") or {}
        if current.get("content") != want["instructions"]:
            change(key, f"write agent {want['name']} instructions",
                   lambda agent_id=agent_id: call("PUT", f"/agents/{agent_id}/instructions-bundle/file",
                                                  {"path": "AGENTS.md", "content": want["instructions"]}))
        if (have.get("runtimeConfig") or {}).get("aiConnection"):
            say(key, f"agent {want['name']} is bound to an AI connection, which gives every run a throwaway "
                     "home; the API cannot remove the binding (clear runtime_config.aiConnection in the database)")
    declared = {a["name"] for a in agents.values()}
    for name in sorted(existing.keys() - declared):
        say(key, f"agent {name} exists but is not declared (left alone)")


def reconcile_connections(key, spec):
    company = spec["id"]
    connections = spec.get("connections", {})
    listing = call("GET", f"/companies/{company}/tools/connections")
    if isinstance(listing, dict):
        listing = listing.get("connections", [])
    existing = {
        c["name"]: c for c in listing
        if c.get("status") != "archived" and c.get("transport") != "runtime_auth"
    }
    for want in connections.values():
        if want["name"] in existing:
            continue
        secret = os.environ.get(want["credentialEnv"])
        if not secret:
            say(key, f"connection {want['name']}: ${want['credentialEnv']} is not set; skipped")
            continue

        def connect(want=want, secret=secret):
            result = call("POST", f"/companies/{company}/tools/apps/connect", {
                "galleryKey": want["gallery"], "connectionMethodKey": want["method"], "name": want["name"],
                "credentialValues": {want["credentialField"]: secret},
            })
            call("POST", f"/companies/{company}/tools/apps/{result['connectionId']}/finish", {
                "enabledCatalogEntryIds": [e["id"] for e in result.get("catalog", [])],
                "askFirstCatalogEntryIds": [], "access": "all_agents",
            })
        change(key, f"connect {want['name']}", connect)
    declared = {c["name"] for c in connections.values()}
    for name in sorted(existing.keys() - declared):
        say(key, f"connection {name} exists but is not declared (left alone)")


def main():
    failed = False
    for key, spec in sorted(DESIRED["companies"].items()):
        for step in (reconcile_company_settings, reconcile_skills, reconcile_agents, reconcile_connections):
            try:
                step(key, spec)
            except Exception as err:  # one failing step must not stop the others
                failed = True
                say(key, f"{step.__name__} failed: {err}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
