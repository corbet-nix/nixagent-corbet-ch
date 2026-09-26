# SPDX-License-Identifier: MIT OR Apache-2.0
"""Quota failover: move an agent to its declared fallback adapter while its own provider's
subscription quota is scarce, and back once it recovers.

Paperclip itself only waits out a quota window (runs fail as provider_quota and are retried
after the reset). The switch here uses Paperclip's own quota reading (/costs/quota-windows):
the busiest window of each provider decides. Unknown usage never triggers a switch.
"""
from api import DESIRED, call

PROVIDER = {"claude_local": "anthropic", "codex_local": "openai", "grok_local": "xai"}


def quota_usage(company):
    """Busiest window per provider, in percent; {} when Paperclip cannot say."""
    try:
        data = call("GET", f"/companies/{company}/costs/quota-windows")
    except Exception:
        return {}
    providers = data if isinstance(data, list) else (data or {}).get("providers", [])
    usage = {}
    for p in providers:
        used = [w["usedPercent"] for w in p.get("windows", []) if isinstance(w.get("usedPercent"), (int, float))]
        if p.get("ok") and used:
            usage[p["provider"]] = max(used)
    return usage


def adapter_for(want, current, usage):
    """The adapter type the agent should run on now."""
    primary = want["adapterType"]
    fallback = (want.get("fallback") or {}).get("adapterType")
    if not fallback:
        return primary
    policy = DESIRED["quotaFailover"]
    primary_used = usage.get(PROVIDER.get(primary))
    fallback_used = usage.get(PROVIDER.get(fallback))
    if current == fallback:
        return primary if primary_used is not None and primary_used < policy["switchBackBelow"] else fallback
    scarce = primary_used is not None and primary_used >= policy["switchAt"]
    if scarce and (fallback_used is None or fallback_used < policy["switchAt"]):
        return fallback
    return primary


def adapter_config(want, adapter_type):
    """Declared settings for whichever adapter the agent runs on, over agentDefaults."""
    own = want["adapterConfig"] if adapter_type == want["adapterType"] else want["fallback"]["adapterConfig"]
    return {**DESIRED["agentDefaults"].get(adapter_type, {}), **own}
