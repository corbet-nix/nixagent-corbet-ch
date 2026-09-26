# SPDX-License-Identifier: MIT OR Apache-2.0
"""Shared plumbing: the desired state, the API call, report/enforce, and small helpers."""
import hashlib
import hmac
import json
import os
import urllib.error
import urllib.request

DESIRED = json.load(open(os.environ["NIXAGENT_PAPERCLIP_DESIRED"]))
API = DESIRED["api"]
TOKEN = os.environ["PAPERCLIP_BOARD_TOKEN"]
HEADERS = {"Host": DESIRED["host"], "Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"}
ENFORCE = DESIRED["mode"] == "enforce"
HOME = os.environ.get("HOME", "/paperclip")


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


