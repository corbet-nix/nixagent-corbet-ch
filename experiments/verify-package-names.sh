#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Reproduces the verification every `arch` name in lib/agents.nix was checked against before being
# committed. Run it by hand after touching the catalogue -- repository membership is a fact about
# the world, it changes without this repo changing, and no eval-time check can see it (that is
# exactly the line checks/agents-eval.nix's own header draws around itself).
#
# THREE SOURCES, NOT ONE, and the third is not optional. `pacman -Si` reports which repository a
# name resolves in ON THIS HOST -- which on an Arch DERIVATIVE includes that derivative's own
# repositories. A name can therefore pass `pacman -Si` cleanly and still be in no upstream Arch
# repository at all, which would make `aur = false` correct on the machine running this script and
# a whole-transaction abort on a plain Arch box ("target not found" fails a `pacman -S` atomically
# and takes every unrelated package in the same converge with it). That is not hypothetical: it is
# `claude-code`, the reason `archRepoOn` exists. So:
#
#   1. archlinux.org's package search API  -- upstream Arch, the authority for `aur = false`.
#   2. the AUR RPC                         -- the authority for `aur = true`.
#   3. `pacman -Si`, if pacman is present  -- informational: shows what THIS host resolves, and
#                                             confirms an `archRepoOn` derivative claim when run
#                                             on that derivative.
#
# The nixpkgs side is inverted here compared to every sibling repo's version of this script: there
# is nothing to resolve, because the catalogue's `nixpkgs = null` is a POLICY (these tools
# self-update; a read-only store path cannot run their updater, and nixpkgs measurably lags them --
# see lib/agents.nix's header). That policy is enforced at eval time by checks/agents-eval.nix, so
# it is not re-checked here.
#
# THE SECOND DELIVERY PLANE IS CHECKED HERE TOO, and it needs this file more than the first one
# does. An installer `upstream.url` is a vendor-controlled URL that can 404, move, or start
# answering with an HTML error page, and none of that changes anything in this repo. checks/ cannot
# see it (a pure evaluation has no network) and checks/upstream-install.nix deliberately stubs curl
# so it tests behaviour rather than the internet. The npx path has the same moving fact at the npm
# registry, so its unversioned package spec is probed here too.
#
# The AUR pass also reports each package's VERSION and out-of-date flag rather than just its
# existence. That is not decoration: an AUR name that exists but is ten releases behind is the
# whole finding behind studies/the-aur-lags-upstream-too.md, and a run of this script is where an
# operator would notice it happening again.
#
# NAMES ARE READ OUT OF lib/agents.nix, never hand-maintained in this file -- a duplicated list
# goes stale in both directions, silently skipping entries that were added and still "verifying"
# entries that were removed.
#
# Usage: ./experiments/verify-package-names.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Pure builtins on purpose: this only reads an attrset of strings, so it must work on a host with
# no <nixpkgs> channel at all.
catalogue_names() {
  local filter="$1"
  nix-instantiate --eval --strict --expr "
    let
      cat = import ./lib/agents.nix { };
      entries = builtins.concatLists (map builtins.attrValues (builtins.attrValues cat));
      want = builtins.filter (t: ${filter}) entries;
    in builtins.concatStringsSep \" \" (map (t: t.arch) want)
  " | sed 's/^\"//; s/\"$//'
}

read -r -a official_names <<<"$(catalogue_names '!(t.aur or false)')"
read -r -a aur_names <<<"$(catalogue_names '(t.aur or false)')"

# The upstream plane's half of the catalogue, as `key|url|runner` triples. Same pure-builtins
# reading as above, and the same reason: a hand-kept second list would go stale in both directions.
catalogue_upstreams() {
  nix-instantiate --eval --strict --expr '
    let
      cat = import ./lib/agents.nix { };
      groups = builtins.attrValues cat;
      pairs = builtins.concatLists (map (g:
        map (k: { name = k; entry = g.${k}; }) (builtins.attrNames g)) groups);
      want = builtins.filter
        (p: p.entry.upstream != null && p.entry.upstream.kind == "installer") pairs;
    in builtins.concatStringsSep " "
      (map (p: "${p.name}|${p.entry.upstream.url}|${p.entry.upstream.runner}") want)
  ' | sed 's/^"//; s/"$//'
}

read -r -a upstreams <<<"$(catalogue_upstreams)"

catalogue_npx_packages() {
  nix-instantiate --eval --strict --expr '
    let
      cat = import ./lib/agents.nix { };
      groups = builtins.attrValues cat;
      pairs = builtins.concatLists (map (g:
        map (k: { name = k; entry = g.${k}; }) (builtins.attrNames g)) groups);
      want = builtins.filter
        (p: p.entry.upstream != null && p.entry.upstream.kind == "npx") pairs;
    in builtins.concatStringsSep " "
      (map (p: "${p.name}|${p.entry.upstream.package}") want)
  ' | sed 's/^"//; s/"$//'
}

read -r -a npx_packages <<<"$(catalogue_npx_packages)"

# Derivative repository names that differ from the plain-Arch/AUR floor, as `distro|package`
# pairs. These cannot be verified by the Arch API or AUR RPC because the derivative owns them.
catalogue_repository_overrides() {
  nix-instantiate --eval --strict --expr '
    let
      cat = import ./lib/agents.nix { };
      entries = builtins.concatLists (map builtins.attrValues (builtins.attrValues cat));
      pairs = builtins.concatLists (map (t:
        map (d: "${d}|${t.archPackageOn.${d}}")
          (builtins.attrNames (t.archPackageOn or { }))) entries);
    in builtins.concatStringsSep " " pairs
  ' | sed 's/^"//; s/"$//'
}

read -r -a repository_overrides <<<"$(catalogue_repository_overrides)"

status=0

echo "== Upstream Arch official repos (archlinux.org package search) -- ${#official_names[@]} name(s) =="
echo "   These carry aur = false, so they MUST exist here or a plain Arch host's pacman transaction aborts."
for pkg in "${official_names[@]}"; do
  count="$(curl -sf "https://archlinux.org/packages/search/json/?name=$pkg" \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["results"]))' 2>/dev/null || echo 0)"
  if [[ "$count" -gt 0 ]]; then
    repo="$(curl -sf "https://archlinux.org/packages/search/json/?name=$pkg" \
      | python3 -c 'import json,sys; r=json.load(sys.stdin)["results"][0]; print(r["repo"], r["pkgver"]+"-"+r["pkgrel"])')"
    echo "OK   $pkg -- $repo"
  else
    echo "FAIL $pkg -- NOT in any upstream Arch repository. lib/agents.nix must mark it aur = true"
    echo "     (with an archRepoOn entry if a derivative's own repository carries it)."
    status=1
  fi
done

echo
echo "== The AUR (aur.archlinux.org RPC v5) -- ${#aur_names[@]} name(s) =="
echo "   These carry aur = true, the safe floor; a derivative may still serve them from its own repo."
for pkg in "${aur_names[@]}"; do
  info="$(curl -sf "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
    | python3 -c 'import json,sys,datetime
d = json.load(sys.stdin)
if d["resultcount"] != 1:
    print("MISSING"); raise SystemExit
r = d["results"][0]
flag = r.get("OutOfDate")
when = datetime.datetime.fromtimestamp(flag, datetime.UTC).date().isoformat() if flag else ""
print(r["Version"], ("FLAGGED-OUT-OF-DATE-" + when) if flag else "current")' 2>/dev/null || echo MISSING)"
  case "$info" in
    MISSING | "")
      echo "FAIL $pkg -- not in the AUR either. The name in lib/agents.nix is wrong."
      status=1
      ;;
    *FLAGGED-OUT-OF-DATE-*)
      # NOT a failure. The name is right and this script's job is the name. It is printed loudly
      # because it is the signal that this entry's distro plane has stopped tracking upstream, and
      # that a host wanting it current should be on `nixagent.home.upstream` instead.
      echo "WARN $pkg (AUR) -- $info"
      ;;
    *)
      echo "OK   $pkg (AUR) -- $info"
      ;;
  esac
done

echo
echo "== Vendor installers (upstream delivery plane) -- ${#upstreams[@]} entry/entries =="
echo "   Each must still answer over HTTPS and still be a shell script. Neither is checkable at eval time."
for triple in "${upstreams[@]}"; do
  IFS='|' read -r key url runner <<<"$triple"
  body="$(mktemp)"
  if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "$body" "$url"; then
    echo "FAIL $key -- $url did not answer (curl exit $?). lib/agents.nix's upstream.url is stale."
    status=1
    rm -f "$body"
    continue
  fi
  first="$(head -1 "$body")"
  case "$first" in
    '#!'*)
      echo "OK   $key -- $url ($(wc -l <"$body" | tr -d ' ') lines, runner: $runner, shebang: $first)"
      ;;
    *)
      echo "FAIL $key -- $url answered, but with something that is not a shell script: $first"
      echo "     A 200 carrying an HTML error page reads exactly like this. lib/install-upstream.sh"
      echo "     refuses it at activation; this is where you find out before a host does."
      status=1
      ;;
  esac
  rm -f "$body"
done

echo
echo "== Vendor npx packages (upstream delivery plane) -- ${#npx_packages[@]} entry/entries =="
for pair in "${npx_packages[@]}"; do
  IFS='|' read -r key package <<<"$pair"
  encoded="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$package")"
  info="$(curl -sf "https://registry.npmjs.org/$encoded" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["name"], d["dist-tags"]["latest"])' \
    2>/dev/null || true)"
  if [[ "$info" == "$package "* ]]; then
    echo "OK   $key -- $info"
  else
    echo "FAIL $key -- npm package $package did not resolve with a latest tag"
    status=1
  fi
done

echo
if command -v pacman >/dev/null 2>&1; then
  echo "== What THIS host resolves (pacman -Si) -- informational, never the authority for \`aur\` =="
  for pkg in "${official_names[@]}" "${aur_names[@]}"; do
    # `sed -n 1p` rather than `head -1`, and the pacman output captured before it is filtered.
    # `head` closes the pipe after one line, which SIGPIPEs pacman, which under `set -o pipefail`
    # made this branch fail non-deterministically -- a package that IS in a repository was reported
    # as "(no repository on this host)" depending on how much output pacman had already flushed.
    if out="$(pacman -Si "$pkg" 2>/dev/null)" \
      && line="$(printf '%s\n' "$out" | sed -n 's/^Repository *: *//p' | sed -n 1p)" \
      && [[ -n "$line" ]]; then
      echo "     $pkg -> $line"
    else
      echo "     $pkg -> (no repository on this host; expected for an AUR name here)"
    fi
  done
else
  echo "== pacman not present -- skipping the host-local view (the two authorities above already ran) =="
fi

echo
echo "== Derivative package-name overrides -- ${#repository_overrides[@]} name(s) =="
current_distro=""
if [[ -r /etc/os-release ]]; then
  current_distro="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | sed -n 1p)"
fi
for pair in "${repository_overrides[@]}"; do
  IFS='|' read -r distro pkg <<<"$pair"
  if [[ "$current_distro" != "$distro" ]] || ! command -v pacman >/dev/null 2>&1; then
    echo "SKIP $distro/$pkg -- requires a live $distro pacman repository view"
  elif out="$(pacman -Si "$pkg" 2>/dev/null)" \
    && repo="$(printf '%s\n' "$out" | sed -n 's/^Repository *: *//p' | sed -n 1p)" \
    && [[ -n "$repo" ]]; then
    echo "OK   $distro/$pkg -> $repo"
  else
    echo "FAIL $distro/$pkg -- archPackageOn names a package this derivative cannot resolve"
    status=1
  fi
done

echo
if [[ $status -eq 0 ]]; then
  echo "All names verified against upstream Arch and the AUR."
else
  echo "One or more names failed verification -- see FAIL lines above." >&2
  exit 1
fi
