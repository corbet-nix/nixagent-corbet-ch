# SPDX-License-Identifier: MIT OR Apache-2.0
"""Problems only a person (or the commit agent) can fix, as self-updating, self-closing issues."""
import os
import subprocess

from api import DESIRED, HOME, call, change, items

ATTENTION_TAG = "[nixagent]"


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


