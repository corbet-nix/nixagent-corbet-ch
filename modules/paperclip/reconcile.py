# SPDX-License-Identifier: MIT OR Apache-2.0
"""nixagent.paperclip reconciler: keeps a Paperclip instance matching its Nix declaration.

Runs in the pod's reconciler sidecar every few minutes against the local API with a board key.
The desired state is the JSON the module renders (NIXAGENT_PAPERCLIP_DESIRED). What is declared
is reconciled; what exists but is not declared is only reported, so agents may still hire and
the board may still experiment. In mode "report" nothing is written and every intended change is
printed with "would"; in mode "enforce" changes are applied. Every pass is idempotent.

Per company (declared ones are created when missing, under their issue prefix and then renamed,
which keeps the prefix on a self-hosted instance):
  * name, description, hire approval; a default local_encrypted secrets vault;
  * the library listing, for companies whose id is declared (only those have the library
    bind-mounted as their managed-skill directory);
  * agents: hired and approved when missing, then kept to their declared title, role, manager,
    adapter keys, permissions, heartbeat, Paperclip skills and instructions;
  * every agent, declared or not, kept to agentDefaults for its adapter type;
  * API-key tool connections (created when missing, their credential rotated when its value
    changes) and company secrets (created, rotated when their value changes); an HMAC in the
    secret's providerMetadata detects change without reading values back.
Attention: problems nobody should have to go looking for become ONE issue each on the board of
the attention company, updated while they last and closed when they are gone: sign-ins that
have lapsed, agents bound to an AI connection, and skill changes waiting to be committed (that
issue is assigned to the commit agent), plus companies whose id is not declared yet (also the
commit agent's, who records it). Never touched: tasks, runs and history.
"""
import hashlib
import hmac
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

DESIRED = json.load(open(os.environ["NIXAGENT_PAPERCLIP_DESIRED"]))
API = DESIRED["api"]
TOKEN = os.environ["PAPERCLIP_BOARD_TOKEN"]
HEADERS = {"Host": DESIRED["host"], "Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"}
ENFORCE = DESIRED["mode"] == "enforce"
HOME = os.environ.get("HOME", "/paperclip")
ATTENTION_TAG = "[nixagent]"


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers=HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=180) as res:
            raw = res.read()
    except urllib.error.HTTPError as err:
        raise RuntimeError(f"{method} {path}: HTTP {err.code} {err.read()[:300]!r}") from None
    return json.loads(raw) if raw else None


def items(listing, key):
    return listing.get(key, []) if isinstance(listing, dict) else (listing or [])


def say(company, message):
    print(f"[{company}] {message}", flush=True)


def change(company, message, action):
    """Apply `action` in enforce mode; in report mode only say what would happen."""
    if ENFORCE:
        result = action()
        say(company, message)
        return result
    say(company, "would " + message)
    return None


def differs(declared, current):
    return {k: v for k, v in declared.items() if (current or {}).get(k) != v}


def fingerprint(value):
    return hmac.new(TOKEN.encode(), value.encode(), hashlib.sha256).hexdigest()[:32]


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


def reconcile_agents(key, company, spec, attention):
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
        adapter_config = {**DESIRED["agentDefaults"].get(want["adapterType"], {}), **want["adapterConfig"]}
        have = existing.get(want["name"])
        if have is None:
            payload = {
                "name": want["name"], "title": want.get("title"), "role": want["role"],
                "adapterType": want["adapterType"], "adapterConfig": adapter_config,
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
        patch = differs({"title": want.get("title"), "role": want["role"]}, have)
        if (have.get("reportsTo") or None) != boss_id:
            patch["reportsTo"] = boss_id
        config_patch = differs(adapter_config, have.get("adapterConfig"))
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


# ── attention ────────────────────────────────────────────────────────────────────────────────
def check_logins(attention):
    def run(*cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            return None
    claude = run("claude", "auth", "status")
    if claude is not None and '"loggedIn": true' not in claude.stdout:
        attention["board"].append("**Claude** is signed out in the pod. Run `claude auth login` in the paperclip container and paste the code back.")
    codex = run("codex", "login", "status")
    if codex and codex.returncode != 0:
        attention["board"].append('**Codex** is signed out in the pod. Run `codex -c cli_auth_credentials_store="file" login --device-auth` in the paperclip container.')
    grok_cli = os.path.join(HOME, ".local/cli/bin/grok")
    if os.path.exists(grok_cli) and not os.path.exists(os.path.join(HOME, ".grok/auth.json")):
        attention["board"].append("**Grok** is signed out in the pod. Run `grok login --device-auth` in the paperclip container.")


def check_uncommitted_skills(attention):
    library = DESIRED["skills"]["library"]
    repo = library
    while repo != "/" and not os.path.exists(os.path.join(repo, ".git")):
        repo = os.path.dirname(repo)
    if repo == "/":
        return
    rel = os.path.relpath(library, repo)
    status = subprocess.run(["git", "-C", repo, "status", "--porcelain", "--", rel], capture_output=True, text=True, timeout=60)
    changed = [line for line in status.stdout.splitlines() if line.strip()]
    if changed:
        attention["commit"] = (repo, rel, changed)


def upsert_issue(key, company, title, body, assignee=None):
    issues = items(call("GET", f"/companies/{company}/issues"), "issues")
    open_issue = next((i for i in issues if i.get("title") == title and i.get("status") not in ("done", "cancelled")), None)
    if body is None:
        if open_issue:
            change(key, f"close attention issue {title!r}", lambda: call("PATCH", f"/issues/{open_issue['id']}", {"status": "done"}))
        return
    if open_issue is None:
        payload = {"title": title, "description": body, "status": "todo"}
        if assignee:
            payload["assigneeAgentId"] = assignee
        change(key, f"open attention issue {title!r}", lambda: call("POST", f"/companies/{company}/issues", payload))
    elif (open_issue.get("description") or "") != body:
        change(key, f"update attention issue {title!r}", lambda: call("PATCH", f"/issues/{open_issue['id']}", {"description": body}))


def report_attention(ids, attention):
    target = DESIRED["attention"]
    if not target.get("company") or target["company"] not in ids or not ids[target["company"]]:
        return
    key, company = target["company"], ids[target["company"]]
    board = attention["board"]
    upsert_issue(key, company, f"{ATTENTION_TAG} Paperclip needs you", None if not board else
                 "The reconciler found things only a person can fix. This issue updates itself and closes when they are gone.\n\n"
                 + "\n".join(f"- {line}" for line in board))
    commit = attention.get("commit")
    assignee = None
    if target.get("commitAgent"):
        agents = {a["name"]: a["id"] for a in items(call("GET", f"/companies/{company}/agents"), "agents")}
        declared = DESIRED["companies"][key]["agents"].get(target["commitAgent"], {})
        assignee = agents.get(declared.get("name"))
    body = None
    if commit:
        repo, rel, changed = commit
        body = ("Skills were created or edited through Paperclip and are not committed yet. Review the change and commit it; "
                "this issue closes itself once the library is clean.\n\n"
                f"Repository `{repo}`, library `{rel}`:\n\n```\n" + "\n".join(changed[:50]) + "\n```\n\n"
                f"Commit with: `{target['commitCommand']}`")
    upsert_issue(key, company, f"{ATTENTION_TAG} Commit skill changes", body, assignee)
    declare = attention["declare"]
    upsert_issue(key, company, f"{ATTENTION_TAG} Record new company ids", None if not declare else
                 "These companies exist in Paperclip but their id is not declared yet, so the skill library is not "
                 f"mounted for them. Record each id in {target['declarationHint']} and land the change the usual way; "
                 "this issue closes itself once the declaration carries them.\n\n"
                 + "\n".join(f"- `{k}` ({name}): `id = \"{cid}\";`" for k, name, cid in declare), assignee)


def main():
    failed = False
    attention = {"board": [], "declare": []}
    try:
        ids, live = resolve_companies()
    except Exception as err:
        print(f"[*] listing companies failed: {err}", flush=True)
        return 1
    for key, spec in sorted(DESIRED["companies"].items()):
        company = ids.get(key)
        if not company:
            continue
        if not spec.get("id"):
            attention["declare"].append((key, spec["name"], company))
        skills = (lambda: reconcile_skills(key, company)) if spec.get("id") else (lambda: None)
        for step in (lambda: reconcile_company(key, company, spec), skills,
                     lambda: reconcile_agents(key, company, spec, attention), lambda: reconcile_connections(key, company, spec),
                     lambda: reconcile_secrets(key, company, spec)):
            try:
                step()
            except Exception as err:  # one failing step must not stop the others
                failed = True
                say(key, f"step failed: {err}")
    for check in (check_logins, check_uncommitted_skills):
        try:
            check(attention)
        except Exception as err:
            failed = True
            print(f"[*] {check.__name__} failed: {err}", flush=True)
    try:
        report_attention(ids, attention)
    except Exception as err:
        failed = True
        print(f"[*] attention failed: {err}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
