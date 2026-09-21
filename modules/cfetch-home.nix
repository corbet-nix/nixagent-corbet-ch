# SPDX-License-Identifier: MIT OR Apache-2.0
# nixagent's cfetch plane, HOME side: the per-user surface the binary needs to actually act as a
# session brain — the config file, the warm daemon, and the idempotent hook/MCP registration.
# The BINARY arrives on the system plane (./cfetch.nix → the host's AUR reconciler) or from
# cfetch's own flake on a NixOS host; this module never installs it and tolerates its absence
# (a registration that ran before the package landed retries on the next activation).
#
# Why home-manager: everything cfetch touches at registration time is per-user state
# (~/.claude/settings.json, ~/.codex, ~/.gemini, ~/.config/cfetch, a systemd USER unit) — the
# same "a per-user prefix is a per-user concern" line ./home.nix draws for the vendor installers.
#
# The registration is an activation script and not home.file, for the reason infra's own
# claudeBrainLinks records: these files pre-exist unmanaged on every current machine, and
# home.file aborts the whole activation on an existing path it does not own. `cfetch install` is
# the tool's OWN idempotent merge (tagged entries, marker blocks), which is strictly better at
# adopting existing state than anything rendered here could be.
{ config, lib, ... }:
let
  cfg = config.nixagent.cfetch;
  settingsJson = builtins.toJSON cfg.settings;
in
{
  options.nixagent.cfetch = {
    enable = lib.mkEnableOption "cfetch per-user wiring: config, daemon unit, registration";

    binary = lib.mkOption {
      type = lib.types.str;
      default = "/usr/bin/cfetch";
      description = "Absolute path of the cfetch binary (systemd units need one).";
    };

    settings = lib.mkOption {
      type = (lib.types.attrsOf lib.types.anything) // { description = "cfetch config attrset"; };
      default = { };
      description = ''
        Rendered verbatim to ~/.config/cfetch/config.json — cfetch's documented schema
        (brain_root, resident, ring rules, embeddings, capture, governance...). Values only;
        this module has no opinions about them.
      '';
    };

    manageDaemon = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Own the cfetch-daemon systemd user unit.";
    };

    registerAgents = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run `cfetch install` at activation (idempotent tagged merges).";
    };

    registrationAfter = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Additional Home Manager activation entries that must finish before cfetch registers.
        Use this when another module renders an agent instruction file that cfetch marker-merges.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."cfetch/config.json".text = settingsJson;

    systemd.user.services.cfetch-daemon = lib.mkIf cfg.manageDaemon {
      Unit.Description = "cfetch per-host daemon";
      Service = {
        ExecStart = "${cfg.binary} daemon run";
        Restart = "on-failure";
        RestartSec = 5;
      } // lib.optionalAttrs cfg.registerAgents {
        # Package/store-path changes can happen independently of a home
        # activation. Repair embedded absolute hook/MCP paths whenever the
        # daemon starts; `-` keeps registration drift from taking memory
        # serving down, while selfcheck still reports it loudly.
        ExecStartPre = "-${cfg.binary} install";
      };
      Install.WantedBy = [ "default.target" ];
    };

    # A package upgrade replaces /usr/bin/cfetch without restarting the
    # already-running daemon, so ExecStartPre alone cannot repair embedded
    # hook/MCP paths. The path unit gives binary replacement its own oneshot
    # registration path; immutable Nix-store binaries still use activation.
    systemd.user.services.cfetch-register = lib.mkIf cfg.registerAgents {
      Unit.Description = "Repair cfetch agent registration after a binary update";
      Service = {
        Type = "oneshot";
        ExecStart = "-${cfg.binary} install";
      };
    };

    systemd.user.paths.cfetch-register = lib.mkIf cfg.registerAgents {
      Unit.Description = "Watch the cfetch binary for package replacement";
      Path = {
        PathChanged = cfg.binary;
        Unit = "cfetch-register.service";
      };
      Install.WantedBy = [ "default.target" ];
    };

    # This is the literal record returned by lib.hm.dag.entryAfter. Keeping the
    # small record here makes this module evaluable in the flake's checks without
    # importing Home Manager as a second flake input.
    home.activation.cfetchRegister = lib.mkIf cfg.registerAgents {
      after = [ "writeBoundary" ] ++ cfg.registrationAfter;
      before = [ ];
      data = ''
        if [ -x ${lib.escapeShellArg cfg.binary} ]; then
          run ${lib.escapeShellArg cfg.binary} install || \
            echo "cfetch install failed (non-fatal; re-runs next activation)" >&2
        else
          echo "cfetch binary not present yet at ${cfg.binary}; registration deferred" >&2
        fi
      '';
    };
  };
}
