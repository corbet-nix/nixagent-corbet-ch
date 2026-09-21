# SPDX-License-Identifier: MIT OR Apache-2.0
# nixagent's cfetch plane, SYSTEM side: publishes the package name a host's own reconciler
# consumes. Installs nothing itself — same "published, not wired" split ./nixagent.nix documents
# for the catalogue lists, for the same reason: the host owns the one concatenation point.
#
# ── WHY cfetch SITS BESIDE THE CATALOGUE, NOT IN IT ────────────────────────────────────────────
#
# ../lib/agents.nix catalogues clients of REMOTE frontier models whose defining property is that
# they SELF-UPDATE, which is what makes nixpkgs ownership structurally impossible for them. cfetch
# fails that membership test on both halves: it drives no model (it is the local memory/retrieval
# layer those clients consult), and it does not self-update — it is a versioned release artifact
# with a tag, a changelog, and its OWN nix flake (github:corbet-labs/cfetch), so nix ownership
# is not merely possible but the natural NixOS plane. Forcing it into the catalogue would make
# that file's loudest invariant ("every entry carries nixpkgs = null, and the reason is
# self-update") false for one row. A tool this repo's domain covers but the catalogue's rule does
# not gets its own module — the same reasoning that keeps the catalogue itself out of nixsh.
#
# ── THE AUR NAME IS NOT THE TOOL'S NAME, AND THAT IS A FINDING, NOT A CHOICE ───────────────────
#
# AUR package base `cfetch` was already taken (an unrelated C system-info fetcher, 1.0.2, checked
# 2026-08-21), so the package base is `cfetch-agent`, carrying provides/conflicts on `cfetch` and
# still installing /usr/bin/cfetch. On CachyOS and plain Arch alike this is AUR-only —
# no repository carries it — so the name lands on the AUR list unconditionally; there is no
# `archRepoOn` to resolve, and putting it on the pacman list would abort the whole transaction.
{ config, lib, ... }:
let
  cfg = config.nixagent.cfetch;
in
{
  options.nixagent.cfetch = {
    enable = lib.mkEnableOption "cfetch, the privilege-ring memory brain for agent sessions";

    package = lib.mkOption {
      type = lib.types.str;
      default = "cfetch-agent";
      description = "AUR package base to publish for the host's reconciler.";
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "What the host's AUR reconciler should install. Empty unless enabled.";
    };
  };

  # The single definition a read-only option allows: computed, never assigned by consumers.
  config.nixagent.cfetch.aurPackages = lib.optional cfg.enable cfg.package;
}
