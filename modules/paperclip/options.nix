# SPDX-License-Identifier: MIT OR Apache-2.0
# The nixagent.paperclip option surface. The rendering is ./default.nix; the reconciler that
# applies the organisation is ./reconcile.py.
{ config, lib, ... }:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.nixagent.paperclip;

  agentType = types.submodule {
    options = {
      name = mkOption { type = types.str; description = "Display name; the reconciler matches agents by it."; };
      title = mkOption { type = types.nullOr types.str; default = null; };
      role = mkOption { type = types.str; default = "general"; description = "Paperclip role (ceo, cto, engineer, qa, researcher, general, ...)."; };
      reportsTo = mkOption { type = types.nullOr types.str; default = null; description = "Key of the managing agent in the same company, or null for the board."; };
      adapterType = mkOption { type = types.enum [ "claude_local" "codex_local" "opencode_local" "grok_local" "gemini_local" "cursor_local" "pi_local" "kimi_local" ]; };
      adapterConfig = mkOption { type = types.attrsOf types.anything; default = { }; description = "Adapter settings the reconciler keeps (keys not listed are left alone)."; };
      instructions = mkOption { type = types.lines; description = "The agent's AGENTS.md."; };
      desiredSkills = mkOption {
        type = types.listOf types.str;
        default = [ "paperclipai/paperclip/paperclip" ];
        description = ''
          Paperclip-library skills attached to the agent. Leave the shared library out: every
          client already loads it from the home, and attaching it would load it twice.
        '';
      };
      permissions = mkOption { type = types.attrsOf types.bool; default = { }; };
      heartbeat = mkOption { type = types.attrsOf types.anything; default = { enabled = false; wakeOnDemand = true; }; };
    };
  };

  connectionType = types.submodule {
    options = {
      name = mkOption { type = types.str; description = "Display name; the reconciler matches connections by it."; };
      gallery = mkOption { type = types.str; example = "github"; description = "Paperclip tool-gallery key."; };
      method = mkOption { type = types.str; example = "mcp-key"; description = "The gallery app's API-key connection method."; };
      credentialEnv = mkOption { type = types.str; description = "Reconciler environment variable holding the credential."; };
      credentialField = mkOption { type = types.str; default = "credentials.authorization"; };
    };
  };

  secretType = types.submodule {
    options = {
      env = mkOption { type = types.str; description = "Reconciler environment variable holding the value (see reconciler.secretEnv)."; };
      description = mkOption { type = types.str; default = ""; };
    };
  };

  companyType = types.submodule {
    options = {
      id = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Paperclip id of the company. The skill-library mount needs it, so a company declared
          without one is created by the reconciler (or matched by name), and its id is handed to
          the commit agent as an issue to record here.
        '';
      };
      name = mkOption { type = types.str; };
      description = mkOption { type = types.nullOr types.str; default = null; };
      issuePrefix = mkOption {
        type = types.nullOr (types.strMatching "[A-Z]{1,3}");
        default = null;
        description = ''
          Issue prefix for a company the reconciler creates: it creates the company under this
          name (Paperclip derives the prefix from the first three letters) and then renames it,
          which keeps the prefix on a self-hosted instance. Only reported for existing companies.
        '';
      };
      requireBoardApprovalForNewAgents = mkOption { type = types.bool; default = true; };
      agents = mkOption { type = types.attrsOf agentType; default = { }; };
      connections = mkOption { type = types.attrsOf connectionType; default = { }; };
      secrets = mkOption {
        type = types.attrsOf secretType;
        default = { };
        description = "Company secrets, by Paperclip name, kept equal to their reconciler environment values (created, rotated on change).";
      };
    };
  };
in
{
  options.nixagent.paperclip = {
    enable = mkEnableOption "a declared Paperclip agent company";
    appName = mkOption { type = types.str; default = "paperclip"; };
    namespace = mkOption { type = types.str; };
    createNamespace = mkOption { type = types.bool; default = false; };
    project = mkOption { type = types.str; default = "default"; description = "Argo CD project."; };
    image = mkOption { type = types.str; description = "The Paperclip image, pinned by digest. A new image migrates the database on first boot."; };
    host = mkOption { type = types.str; example = "paperclip.example.org"; description = "The public host name; also sent by probes and the reconciler, since Paperclip refuses other Host headers."; };
    port = mkOption { type = types.port; default = 3100; };
    runAsUser = mkOption { type = types.int; };
    runAsGroup = mkOption { type = types.int; };
    hostname = mkOption { type = types.str; default = cfg.appName; description = "The pod's hostname, also the key agents use to pick their mind."; };
    nodeSelector = mkOption { type = types.attrsOf types.str; default = { }; };
    priorityClassName = mkOption { type = types.nullOr types.str; default = null; };
    clusterIP = mkOption { type = types.nullOr types.str; default = null; };
    allowSignUp = mkOption { type = types.bool; default = false; };
    resources = mkOption {
      type = types.attrsOf types.anything;
      default = { requests = { cpu = "500m"; memory = "1Gi"; }; limits = { cpu = "8"; memory = "16Gi"; }; };
      description = "The server container's resources; they bound every agent run together.";
    };
    env = mkOption { type = types.attrsOf types.str; default = { }; description = "Extra plain environment of the server and every agent."; };
    secretEnvFrom = mkOption { type = types.listOf types.str; default = [ ]; description = "Secrets whose keys become the server's (and every agent's) environment."; };

    home = {
      path = mkOption { type = types.str; default = "/paperclip"; };
      hostPath = mkOption { type = types.str; description = "Persistent home: config, logins, checkouts, per-agent state."; };
    };

    nix = {
      hostPath = mkOption { type = types.nullOr types.str; default = null; description = "A single-user /nix store for the agents, or null for none."; };
      image = mkOption { type = types.str; default = "nixos/nix"; description = "Seeds the store once."; };
      config = mkOption { type = types.lines; default = "experimental-features = nix-command flakes\n"; };
    };

    brain = {
      root = mkOption { type = types.str; description = "The shared knowledge store, at the same path inside the pod as on the hosts."; };
      hostPath = mkOption { type = types.str; };
      skills = mkOption { type = types.str; description = "The one skill library, inside the pod."; };
      skillsHostPath = mkOption { type = types.str; description = "The same library on the node, bind-mounted as each declared company's managed-skill directory."; };
      claudeInstructions = mkOption { type = types.nullOr types.lines; default = null; };
      claudeMemoryDir = mkOption { type = types.nullOr types.str; default = null; };
      codexInstructions = mkOption { type = types.nullOr types.lines; default = null; };
    };

    claudeSettings = mkOption { type = types.attrsOf types.anything; default = { }; description = "~/.claude/settings.json"; };
    opencodeConfig = mkOption { type = types.nullOr (types.attrsOf types.anything); default = null; description = "~/.config/opencode/opencode.json"; };
    gitconfig = mkOption { type = types.nullOr types.lines; default = null; };
    clis.grokVersion = mkOption { type = types.nullOr types.str; default = null; description = "Install xAI's @xai-official/grok at this version into the home."; };

    agentDefaults = mkOption {
      type = types.attrsOf (types.attrsOf types.anything);
      default = { claude_local = { engine = "cli"; }; };
      description = ''
        Adapter settings enforced on EVERY agent of an adapter type, declared or hired at run
        time. The default puts Claude agents on the CLI engine, because the ACP engine (Claude
        Agent SDK) does not load the home's skills.
      '';
    };

    reconciler = {
      enable = mkOption { type = types.bool; default = true; };
      mode = mkOption { type = types.enum [ "report" "enforce" ]; default = "report"; };
      interval = mkOption { type = types.ints.positive; default = 300; description = "Seconds between passes."; };
      boardSecret = {
        name = mkOption { type = types.str; description = "Secret holding a board API key, given to the reconciler only."; };
        key = mkOption { type = types.str; default = "PAPERCLIP_BOARD_TOKEN"; };
      };
      secretEnv = mkOption {
        type = types.attrsOf (types.submodule { options = { name = mkOption { type = types.str; }; key = mkOption { type = types.str; }; }; });
        default = { };
        description = "Reconciler-only environment from secrets: connection credentials, company secret values.";
      };
      attention = {
        company = mkOption { type = types.nullOr types.str; default = null; description = "Key of the company whose board receives attention issues (expired logins, stray AI bindings, uncommitted skills), or null for none."; };
        commitAgent = mkOption { type = types.nullOr types.str; default = null; description = "Agent key (in that company) assigned to commit skill changes made through Paperclip."; };
        declarationHint = mkOption {
          type = types.str;
          default = "the file that declares nixagent.paperclip";
          description = "Where the commit agent records a new company's id, shown in its issue.";
        };
        commitCommand = mkOption {
          type = types.str;
          default = "git -C <library> add -A . && git -C <library> commit -m <message>";
          description = "How the assigned agent commits the library, shown in its issue.";
        };
      };
    };

    companies = mkOption { type = types.attrsOf companyType; default = { }; };
  };
}
