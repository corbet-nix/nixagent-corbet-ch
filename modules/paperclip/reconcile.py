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
    adapter keys, permissions, heartbeat, Paperclip skills and instructions, and moved to their
    fallback adapter while their provider's quota is scarce (failover.py);
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
import sys

from api import DESIRED
from attention import check_logins, check_uncommitted_skills, report_attention
from credentials import reconcile_connections, reconcile_secrets
from org import ordered_agents, quota_usage, reconcile_agents, reconcile_company, reconcile_skills, resolve_companies  # noqa: F401 (ordered_agents: checks)


def main():
    failed = False
    attention = {"board": [], "declare": []}
    try:
        ids, live = resolve_companies()
    except Exception as err:
        print(f"[*] listing companies failed: {err}", flush=True)
        return 1
    # Quota is per account, not per company: read it once for the pass.
    usage = quota_usage(next(iter(ids.values()))) if any(ids.values()) else {}
    for key, spec in sorted(DESIRED["companies"].items()):
        company = ids.get(key)
        if not company:
            continue
        if not spec.get("id"):
            attention["declare"].append((key, spec["name"], company))
        skills = (lambda: reconcile_skills(key, company)) if spec.get("id") else (lambda: None)
        for step in (lambda: reconcile_company(key, company, spec), skills,
                     lambda: reconcile_agents(key, company, spec, attention, usage), lambda: reconcile_connections(key, company, spec),
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
