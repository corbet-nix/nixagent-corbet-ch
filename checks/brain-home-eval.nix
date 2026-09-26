# SPDX-License-Identifier: MIT OR Apache-2.0
# Evaluates ../modules/brain-home.nix against the small Home Manager surface it writes: the
# activation step names consumers order after, the refresh timer, and the disabled state.
# checks/brain-links.nix RUNS the snippets these steps carry.
{ pkgs, lib ? pkgs.lib }:
let
  homeSurfaceStub = { lib, ... }: {
    options = {
      home.homeDirectory = lib.mkOption { type = lib.types.str; default = "/home/alice"; };
      systemd.user.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      systemd.user.timers = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      home.activation = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
    };
  };

  evalWith = selection: (lib.evalModules {
    modules = [ homeSurfaceStub ../modules/brain-home.nix { _module.args.pkgs = pkgs; nixagent.brain = selection; } ];
  }).config;

  disabled = evalWith { skills = "/home/alice/brain/skills"; };
  enabled = evalWith {
    enable = true;
    skills = "/home/alice/brain/skills";
    claude.instructions = "@~/brain/AGENTS.md";
    codex.instructions = "Read ~/brain/AGENTS.md.";
  };
  noTimer = evalWith { enable = true; skills = "/home/alice/brain/skills"; refresh = null; };

  results = {
    "disabled brain contributes no managed home surfaces" =
      disabled.home.activation == { } && disabled.systemd.user.services == { }
      && disabled.systemd.user.timers == { };
    "activation keeps the step names consumers order after" =
      builtins.attrNames enabled.home.activation == [ "agentsSkillLinks" "claudeBrainLinks" "codexBrainLinks" ]
      && enabled.home.activation.codexBrainLinks.after == [ "writeBoundary" ];
    "activation links the library into both skill folders through run" =
      lib.hasInfix ''run ln -sfn "$skill" "/home/alice/.claude/skills/$name"'' enabled.home.activation.claudeBrainLinks.data
      && lib.hasInfix ''run ln -sfn "$skill" "/home/alice/.agents/skills/$name"'' enabled.home.activation.agentsSkillLinks.data;
    "the refresh timer re-links every five minutes by default" =
      enabled.systemd.user.timers.nixagent-skill-links.Timer.OnUnitActiveSec == "5min";
    "refresh = null removes the timer" =
      noTimer.systemd.user.timers == { } && noTimer.systemd.user.services == { };
  };
  failed = builtins.attrNames (lib.filterAttrs (_: ok: !ok) results);
in
if failed == [ ] then pkgs.runCommand "nixagent-brain-home-eval" { } "echo ok > $out"
else throw "brain-home-eval failed: ${lib.concatStringsSep "; " failed}"
