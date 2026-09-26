# SPDX-License-Identifier: MIT OR Apache-2.0
"""Companies, their skill listings, and agents (with quota failover)."""
import os

from api import DESIRED, call, change, differs, items, say
from failover import adapter_config, adapter_for, quota_usage


# ── companies ────────────────────────────────────────────────────────────────────────────────
def resolve_companies():
    """Map every declared company key to its live id, creating missing ones."""
    live = items(call("GET", "/companies"), "companies")
    by_id = {c["id"]: c for c in live}
    by_name = {c["name"]: c for c in live}
    ids = {}
    for key, spec in sorted(DESIRED["companies"].items()):
        found = by_id.get(spec.get("id")) or by_name.get(spec["name"])
        if found:
            ids[key] = found["id"]
            continue
        if spec.get("id"):
            say(key, f"declared id {spec['id']} does not exist; skipped")
            continue

        def create(spec=spec):
            # Paperclip derives the prefix from the name's first letters and a self-hosted
            # instance keeps it on rename: create under the prefix, then rename.
            created = call("POST", "/companies", {"name": spec.get("issuePrefix") or spec["name"]})
            call("PATCH", f"/companies/{created['id']}", {"name": spec["name"]})
            return created["id"]
        ids[key] = change(key, f"create company {spec['name']}", create)
    return ids, live


def reconcile_company(key, company, spec):
    current = call("GET", f"/companies/{company}")
    patch = differs({k: spec[k] for k in ("name", "description", "requireBoardApprovalForNewAgents") if spec.get(k) is not None}, current)
    if patch:
        change(key, f"update company settings {sorted(patch)}", lambda: call("PATCH", f"/companies/{company}", patch))
    if spec.get("issuePrefix") and current.get("issuePrefix") != spec["issuePrefix"]:
        say(key, f"issue prefix is {current.get('issuePrefix')}, declared {spec['issuePrefix']} (the API cannot change it)")
    vaults = items(call("GET", f"/companies/{company}/secret-provider-configs"), "configs")
    if not any(v.get("provider") == "local_encrypted" and v.get("isDefault") for v in vaults):
        change(key, "create the default local secrets vault", lambda: call("POST", f"/companies/{company}/secret-provider-configs", {
            "provider": "local_encrypted", "displayName": "Local (master key held outside Paperclip)",
            "isDefault": True, "config": {"backupReminderAcknowledged": True},
        }))


# ── skills ───────────────────────────────────────────────────────────────────────────────────
def reconcile_skills(key, company):
    library = DESIRED["skills"]["library"]
    prefix = f"{DESIRED['skills']['root']}/{company}/"
    shared = {d for d in os.listdir(library) if not d.startswith("__") and os.path.isfile(os.path.join(library, d, "SKILL.md"))}
    listed = {}
    for skill in items(call("GET", f"/companies/{company}/skills"), "skills"):
        locator = skill.get("sourceLocator") or ""
        if locator.startswith(prefix):
            listed[locator[len(prefix):]] = skill["id"]
    for name in sorted(shared - listed.keys()):
        change(key, f"import skill {name}", lambda name=name: call("POST", f"/companies/{company}/skills/import", {"source": prefix + name}))
    for name in sorted(listed.keys() - shared):
        change(key, f"remove skill {name} (its directory is gone)", lambda name=name: call("DELETE", f"/companies/{company}/skills/{listed[name]}"))


# ── agents ───────────────────────────────────────────────────────────────────────────────────
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


# Adapter-config keys that belong to the agent, not to its adapter; kept across a switch.
AGENT_KEYS = ("instructionsFilePath", "instructionsRootPath", "instructionsEntryFile", "instructionsBundleMode", "paperclipSkillSync", "env")


def reconcile_agents(key, company, spec, attention, usage):
    agents = spec.get("agents", {})
    existing = {a["name"]: a for a in items(call("GET", f"/companies/{company}/agents"), "agents")}
    ids = {}
    for agent_key in ordered_agents(agents):
        want = agents[agent_key]
        boss = want.get("reportsTo")
        boss_id = ids.get(boss) if boss else None
        if boss and not boss_id:
            say(key, f"agent {want['name']}: manager {boss} does not exist yet; next pass")
            continue
        have = existing.get(want["name"])
        target = adapter_for(want, have.get("adapterType") if have else None, usage)
        adapter_cfg = adapter_config(want, target)
        if have is None:
            payload = {
                "name": want["name"], "title": want.get("title"), "role": want["role"],
                "adapterType": target, "adapterConfig": adapter_cfg,
                "desiredSkills": want["desiredSkills"], "permissions": want["permissions"],
                "runtimeConfig": {"heartbeat": want["heartbeat"]},
                "instructionsBundle": {"entryFile": "AGENTS.md", "files": {"AGENTS.md": want["instructions"]}},
            }
            if boss_id:
                payload["reportsTo"] = boss_id

            def hire(payload=payload):
                result = call("POST", f"/companies/{company}/agent-hires", payload) or {}
                approval = result.get("approval") or {}
                if approval.get("id"):
                    call("POST", f"/approvals/{approval['id']}/approve", {"decisionNote": "Declared in nixagent.paperclip; approved by its reconciler."})
                return (result.get("agent") or {}).get("id")
            ids[agent_key] = change(key, f"hire agent {want['name']} ({want['adapterType']})", hire)
            continue
        agent_id = ids[agent_key] = have["id"]
        if have.get("adapterType") != target:
            kept = {k: v for k, v in (have.get("adapterConfig") or {}).items() if k in AGENT_KEYS}
            used = ", ".join(f"{p} {u}%" for p, u in sorted(usage.items()))
            change(key, f"switch agent {want['name']} {have.get('adapterType')} -> {target} (quota: {used})",
                   lambda agent_id=agent_id, kept=kept: call("PATCH", f"/agents/{agent_id}", {
                       "adapterType": target, "adapterConfig": {**kept, **adapter_cfg}, "replaceAdapterConfig": True}))
            continue
        patch = differs({"title": want.get("title"), "role": want["role"]}, have)
        if (have.get("reportsTo") or None) != boss_id:
            patch["reportsTo"] = boss_id
        config_patch = differs(adapter_cfg, have.get("adapterConfig"))
        if config_patch:
            patch["adapterConfig"] = config_patch
        heartbeat = (have.get("runtimeConfig") or {}).get("heartbeat") or {}
        if differs(want["heartbeat"], heartbeat):
            patch["runtimeConfig"] = {"heartbeat": {**heartbeat, **want["heartbeat"]}}
        if patch:
            change(key, f"update agent {want['name']} {sorted(patch)}", lambda agent_id=agent_id, patch=patch: call("PATCH", f"/agents/{agent_id}", patch))
        if differs(want["permissions"], have.get("permissions")):
            change(key, f"update agent {want['name']} permissions", lambda agent_id=agent_id: call("PATCH", f"/agents/{agent_id}/permissions", want["permissions"]))
        skills = ((have.get("adapterConfig") or {}).get("paperclipSkillSync") or {}).get("desiredSkills") or []
        if sorted(skills) != sorted(want["desiredSkills"]):
            change(key, f"set agent {want['name']} Paperclip skills", lambda agent_id=agent_id: call("POST", f"/agents/{agent_id}/skills/sync", {"mode": "replace", "desiredSkills": want["desiredSkills"]}))
        current = call("GET", f"/agents/{agent_id}/instructions-bundle/file?path=AGENTS.md") or {}
        if current.get("content") != want["instructions"]:
            change(key, f"write agent {want['name']} instructions", lambda agent_id=agent_id: call("PUT", f"/agents/{agent_id}/instructions-bundle/file", {"path": "AGENTS.md", "content": want["instructions"]}))
    declared = {a["name"] for a in agents.values()}
    for name, have in sorted(existing.items()):
        if name not in declared:
            say(key, f"agent {name} exists but is not declared (left alone apart from agentDefaults)")
            defaults = DESIRED["agentDefaults"].get(have.get("adapterType"), {})
            missing = differs(defaults, have.get("adapterConfig"))
            if missing:
                change(key, f"apply agentDefaults to {name} {sorted(missing)}", lambda have=have, missing=missing: call("PATCH", f"/agents/{have['id']}", {"adapterConfig": missing}))
        if (have.get("runtimeConfig") or {}).get("aiConnection"):
            attention["board"].append(f"Agent **{name}** ({key}) is bound to a Paperclip AI connection, which gives every run a throwaway home without the brain. Clear `runtime_config.aiConnection` for it (the API keeps the binding).")


