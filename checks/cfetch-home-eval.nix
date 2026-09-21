# SPDX-License-Identifier: MIT OR Apache-2.0
# Evaluates ../modules/cfetch-home.nix against the small Home Manager surface it
# writes. This keeps the registration ordering and service restart repair path
# under `nix flake check` without adding Home Manager as a flake input.
{ pkgs, lib ? pkgs.lib }:
let
  homeSurfaceStub = { lib, ... }: {
    options = {
      xdg.configFile = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
      systemd.user.services = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
      systemd.user.paths = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
      home.activation = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
    };
  };

  evalWith = selection: (lib.evalModules {
    modules = [
      homeSurfaceStub
      ../modules/cfetch-home.nix
      { nixagent.cfetch = selection; }
    ];
  }).config;

  disabled = evalWith { };
  defaults = evalWith { enable = true; };
  ordered = evalWith {
    enable = true;
    binary = "/opt/cfetch/bin/cfetch";
    registrationAfter = [ "codexBrainLinks" "otherAgentFiles" ];
  };
  noRegistration = evalWith {
    enable = true;
    registerAgents = false;
  };

  results = {
    "disabled cfetch contributes no managed home surfaces" =
      disabled.xdg.configFile == { }
      && disabled.systemd.user.services == { }
      && disabled.systemd.user.paths == { }
      && disabled.home.activation == { };

    "default registration follows writeBoundary and repairs paths at daemon start" =
      defaults.home.activation.cfetchRegister.after == [ "writeBoundary" ]
      && defaults.home.activation.cfetchRegister.before == [ ]
      && defaults.systemd.user.services.cfetch-daemon.Service.ExecStartPre
      == "-/usr/bin/cfetch install"
      && defaults.systemd.user.services.cfetch-register.Service.ExecStart
      == "-/usr/bin/cfetch install"
      && defaults.systemd.user.paths.cfetch-register.Path.PathChanged
      == "/usr/bin/cfetch"
      && defaults.systemd.user.paths.cfetch-register.Path.Unit
      == "cfetch-register.service";

    "consumer ordering is appended after writeBoundary and reaches the selected binary" =
      ordered.home.activation.cfetchRegister.after
      == [ "writeBoundary" "codexBrainLinks" "otherAgentFiles" ]
      && lib.hasInfix "run /opt/cfetch/bin/cfetch install"
        ordered.home.activation.cfetchRegister.data
      && ordered.systemd.user.services.cfetch-daemon.Service.ExecStartPre
      == "-/opt/cfetch/bin/cfetch install"
      && ordered.systemd.user.services.cfetch-register.Service.ExecStart
      == "-/opt/cfetch/bin/cfetch install"
      && ordered.systemd.user.paths.cfetch-register.Path.PathChanged
      == "/opt/cfetch/bin/cfetch";

    "disabling registration removes both activation and daemon pre-start repair" =
      noRegistration.home.activation == { }
      && !(noRegistration.systemd.user.services.cfetch-daemon.Service ? ExecStartPre)
      && !(noRegistration.systemd.user.services ? cfetch-register)
      && noRegistration.systemd.user.paths == { };
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
then pkgs.emptyFile
else
  throw ''
    nixagent: cfetch-home-eval check failed. Failing assertions:
    ${lib.concatMapStringsSep "\n" (failure: "  - ${failure}") failed}
  ''
