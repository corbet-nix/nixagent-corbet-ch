# SPDX-License-Identifier: MIT OR Apache-2.0
"""Projects: created when missing with a repo-only workspace, then kept described and led.

A declared project's workspace is created once from its repo URL; Paperclip clones it on demand
(authenticating private GitHub repositories with the company's GH_TOKEN secret) and, when the
project is isolated, gives every task its own git worktree and branch. Projects made in the UI
or by agents are only reported, so nobody needs Nix to start one.
"""
from api import call, change, differs, items, say


def reconcile_projects(key, company, spec):
    projects = spec.get("projects", {})
    agents = {a["name"]: a["id"] for a in items(call("GET", f"/companies/{company}/agents"), "agents")}
    existing = {p["name"]: p for p in items(call("GET", f"/companies/{company}/projects"), "projects") if not p.get("archivedAt")}
    for want in projects.values():
        lead = spec["agents"].get(want["lead"], {}).get("name") if want.get("lead") else None
        lead_id = agents.get(lead) if lead else None
        have = existing.get(want["name"])
        if have is None:
            repo = want["repoUrl"].rstrip("/").rsplit("/", 1)[-1]
            payload = {
                "name": want["name"], "description": want.get("description"), "leadAgentId": lead_id,
                "workspace": {"name": repo, "sourceType": "git_repo", "repoUrl": want["repoUrl"], "defaultRef": want["defaultRef"], "isPrimary": True},
            }
            if want["isolated"]:
                payload["executionWorkspacePolicy"] = {
                    "enabled": True, "defaultMode": "isolated_workspace", "allowIssueOverride": True,
                    "workspaceStrategy": {"type": "git_worktree", "baseRef": want["defaultRef"]},
                }
            change(key, f"create project {want['name']} ({want['repoUrl']})", lambda payload=payload: call("POST", f"/companies/{company}/projects", payload))
            continue
        patch = differs({"description": want.get("description"), "leadAgentId": lead_id}, have)
        if patch:
            change(key, f"update project {want['name']} {sorted(patch)}", lambda have=have, patch=patch: call("PATCH", f"/projects/{have['id']}", patch))
        repo_url = ((have.get("primaryWorkspace") or {}).get("repoUrl") or "").rstrip("/")
        if repo_url and repo_url != want["repoUrl"].rstrip("/"):
            say(key, f"project {want['name']} points at {repo_url}, declared {want['repoUrl']} (workspaces are not rewritten)")
    for name in sorted(existing.keys() - {p["name"] for p in projects.values()}):
        say(key, f"project {name} exists but is not declared (left alone)")
