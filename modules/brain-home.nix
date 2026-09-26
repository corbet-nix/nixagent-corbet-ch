# SPDX-License-Identifier: MIT OR Apache-2.0
#
# nixagent.brain -- connect every agent client in this home to ONE shared knowledge store:
# global instructions for Claude Code and Codex, an optional Claude memory directory, and above
# all ONE skill library, linked where each client reads skills (lib/brain.nix says where and why).
#
# The library is the single source: nothing is copied, so a skill edited in the store is the
# skill every client loads, and a skill created or deleted anywhere reaches every client within
# `refresh` through a user timer. The same snippets serve containers without home-manager
# through this flake's `lib.brain`.
#
# The activation steps keep the names claudeBrainLinks, codexBrainLinks and agentsSkillLinks, so
# consumers can order after them (cfetch registration appends to Codex's AGENTS.md and must run
# after codexBrainLinks). The records are the literal shape lib.hm.dag.entryAfter returns, which
# keeps this module evaluable in the flake's checks without Home Manager as an input.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixagent.brain;
  brain = import ../lib/brain.nix;
  home = config.home.homeDirectory;
  after = data: { after = [ "writeBoundary" ]; before = [ ]; inherit data; };
in
{
  options.nixagent.brain = {
    enable = lib.mkEnableOption "connecting this home's agent clients to a shared knowledge store";

    skills = lib.mkOption {
      type = lib.types.str;
      example = "/home/alice/brain/skills";
      description = ''
        The one skill library: a directory of Agent Skills (<name>/SKILL.md). Every skill in it
        is linked into ~/.claude/skills and ~/.agents/skills.
      '';
    };

    claude.instructions = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      example = "@~/brain/AGENTS.md";
      description = "Contents of ~/.claude/CLAUDE.md, or null to leave that file alone.";
    };

    claude.memoryDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/home/alice/brain/memory/$(uname -n)";
      description = ''
        Directory linked as the auto-memory of Claude sessions started in the home directory,
        or null. Expanded by the shell at activation, so $(...) is allowed.
      '';
    };

    codex.instructions = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Contents of ~/.codex/AGENTS.md, or null to leave that file alone.";
    };

    refresh = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "5min";
      description = ''
        How often a user timer re-links the skill library, so new and deleted skills reach every
        client without waiting for the next activation. null disables the timer.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.activation = {
      claudeBrainLinks = after (brain.claude {
        inherit home;
        inherit (cfg) skills;
        instructions = cfg.claude.instructions;
        memoryDir = cfg.claude.memoryDir;
        run = "run";
      });
      agentsSkillLinks = after (brain.agents { inherit home; inherit (cfg) skills; run = "run"; });
      codexBrainLinks = after (brain.codex {
        inherit home;
        inherit (cfg) skills;
        instructions = cfg.codex.instructions;
        run = "run";
      });
    };

    systemd.user.services.nixagent-skill-links = lib.mkIf (cfg.refresh != null) {
      Unit.Description = "Link the shared skill library into every agent client";
      Service = {
        Type = "oneshot";
        ExecStart = toString (pkgs.writeShellScript "nixagent-skill-links" ''
          set -eu
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
          ${brain.skillsOnly { inherit home; inherit (cfg) skills; }}
        '');
      };
    };
    systemd.user.timers.nixagent-skill-links = lib.mkIf (cfg.refresh != null) {
      Unit.Description = "Refresh the shared skill library links";
      Timer = { OnStartupSec = "1min"; OnUnitActiveSec = cfg.refresh; };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
