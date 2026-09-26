# SPDX-License-Identifier: MIT OR Apache-2.0
#
# nixagent.paperclip -- a Paperclip (github.com/paperclipai/paperclip) agent company, declared.
# A nixidy module: it renders the Argo CD application for the Paperclip server AND the
# organisation it runs (companies, agents, their instructions, API-key connections), which a
# reconciler sidecar keeps the live instance matching.
#
# THE POD IS THE AGENTS' WORKSTATION. Paperclip runs every agent as a local CLI (claude, codex,
# opencode, grok) inside this one pod, on the pod's REAL home: no Paperclip-managed AI logins
# (those give every run a throwaway HOME that bypasses the wiring below), logins done once in the
# home like on any host. The home is wired to the shared knowledge store through this flake's
# lib.brain -- the same snippets `nixagent.brain` runs on every host -- so the pod's agents and a
# person's own sessions boot from the same instructions and the same ONE skill library.
#
# SKILLS ARE THE STORE'S. Each company's Paperclip managed-skill directory is a read-write bind
# mount of the shared skill library, so a skill created or edited in Paperclip lands in the
# library and a library edit reaches the next run. A bind mount, not a symlink: Paperclip
# realpath()s local import sources and refuses anything outside its managed root. Paperclip does
# not notice new directories itself; the reconciler keeps each company's listing current.
#
# DECLARED IS ENFORCED, UNDECLARED IS REPORTED. The reconciler creates and corrects what is
# declared and only reports what exists besides it, so agents may still hire and the board may
# still experiment; the declaration catches up by a human decision. mode = "report" writes
# nothing and prints every intended change. Claude agents want adapterConfig.engine = "cli": the
# default ACP engine (Claude Agent SDK) does not load the home's skills.
{ config, lib, ... }:
let
  cfg = config.nixagent.paperclip;
  brain = import ../../lib/brain.nix;
  inherit (lib) mkOption mkEnableOption types;

  home = cfg.home.path;
  skillsRoot = "${home}/instances/default/skills";
  cliPrefix = "${home}/.local/cli";
  dotfilesDir = "/etc/paperclip/home";
  reconcilerDir = "/etc/paperclip/reconciler";
  healthHeaders = [{ name = "Host"; value = cfg.host; }];
  companyIds = lib.filter (id: id != null) (lib.mapAttrsToList (_: c: c.id) cfg.companies);

  agentType = types.submodule {
    options = {
      name = mkOption { type = types.str; description = "Display name; the reconciler matches agents by it."; };
      title = mkOption { type = types.nullOr types.str; default = null; };
      role = mkOption { type = types.str; default = "general"; description = "Paperclip role (ceo, cto, engineer, qa, researcher, general, ...)."; };
      reportsTo = mkOption { type = types.nullOr types.str; default = null; description = "Key of the managing agent in the same company, or null for the board."; };
      adapterType = mkOption { type = types.enum [ "claude_local" "codex_local" "opencode_local" "grok_local" "gemini_local" "cursor_local" "pi_local" "kimi_local" ]; };
      adapterConfig = mkOption {
        type = types.attrsOf types.anything;
        default = { };
        description = "Adapter settings the reconciler keeps (keys not listed are left alone).";
      };
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
      heartbeat = mkOption {
        type = types.attrsOf types.anything;
        default = { enabled = false; wakeOnDemand = true; };
      };
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

  companyType = types.submodule {
    options = {
      id = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The company's Paperclip id. The skill mounts need it, so a company is created in
          Paperclip first and its id recorded here.
        '';
      };
      name = mkOption { type = types.str; };
      description = mkOption { type = types.nullOr types.str; default = null; };
      issuePrefix = mkOption { type = types.nullOr types.str; default = null; description = "Only checked and reported; the API cannot change it."; };
      requireBoardApprovalForNewAgents = mkOption { type = types.bool; default = true; };
      agents = mkOption { type = types.attrsOf agentType; default = { }; };
      connections = mkOption { type = types.attrsOf connectionType; default = { }; };
    };
  };

  # ── rendered pieces ───────────────────────────────────────────────────────────────────────
  path = lib.concatStringsSep ":" ([ "/usr/local/sbin" "/usr/local/bin" "/usr/sbin" "/usr/bin" "/sbin" "/bin" ]
    ++ lib.optional (cfg.clis.grokVersion != null) "${cliPrefix}/bin"
    ++ lib.optionals (cfg.nix.hostPath != null) [ "${home}/.nix-profile/bin" "/nix/var/nix/profiles/default/bin" ]);

  seedNix = ''
    set -eu
    if [ -e /mnt/nix/var/nix/db/db.sqlite ]; then echo "nix store present"; exit 0; fi
    # Non-root: keep modes and links, let ownership become the pod user's.
    cp -dR --preserve=mode,timestamps /nix/. /mnt/nix/
    echo "nix store seeded"
  '';

  grok = cfg.clis.grokVersion;
  installClis = ''
    set -eu
    if [ "$(cat ${cliPrefix}/grok.version 2>/dev/null || true)" = "${grok}" ] \
      && [ -x ${cliPrefix}/bin/grok ]; then
      echo "grok ${grok} present"; exit 0
    fi
    npm install -g --no-fund --no-audit --prefix ${cliPrefix} @xai-official/grok@${grok}
    echo "${grok}" > ${cliPrefix}/grok.version
  '';

  containerSecurity = {
    allowPrivilegeEscalation = false;
    capabilities.drop = [ "ALL" ];
  };

  dotfiles = {
    "claude-settings.json" = builtins.toJSON cfg.claudeSettings;
  } // lib.optionalAttrs (cfg.opencodeConfig != null) {
    "opencode.json" = builtins.toJSON cfg.opencodeConfig;
  } // lib.optionalAttrs (cfg.gitconfig != null) {
    gitconfig = cfg.gitconfig;
  };

  # Links, not subPath mounts: a subPath mount would make the kubelet create root-owned
  # placeholders inside the pod user's home and lock the CLIs out of their config directories.
  linkHome = ''
    set -eu
    link() {
      # ln -sfn onto a real directory would link INSIDE it; refuse instead.
      if [ -e "$2" ] && [ ! -L "$2" ]; then echo "refusing to replace real path $2" >&2; exit 1; fi
      ln -sfn "$1" "$2"
    }
    mkdir -p ${home}/.claude
    # Mountpoints for the per-company skill mounts, created as the pod user so the kubelet does
    # not leave root-owned placeholders in the home.
    mkdir -p ${lib.concatMapStringsSep " " (id: "${skillsRoot}/${id}") companyIds}
    link ${cfg.brain.root} ${home}/agents
    link ${dotfilesDir}/claude-settings.json ${home}/.claude/settings.json
  '' + lib.optionalString (cfg.gitconfig != null) ''
    link ${dotfilesDir}/gitconfig ${home}/.gitconfig
  '' + lib.optionalString (cfg.opencodeConfig != null) ''
    # Copied, not linked: Paperclip copies ~/.config/opencode without dereferencing and then
    # rewrites opencode.json in the copy, which a link into the read-only ConfigMap would turn
    # into a failed write on every OpenCode run.
    mkdir -p ${home}/.config/opencode
    rm -f ${home}/.config/opencode/opencode.json
    cp ${dotfilesDir}/opencode.json ${home}/.config/opencode/opencode.json
  '' + brain.all {
    inherit home;
    inherit (cfg.brain) skills;
    claudeInstructions = cfg.brain.claudeInstructions;
    claudeMemoryDir = cfg.brain.claudeMemoryDir;
    codexInstructions = cfg.brain.codexInstructions;
  };

  desired = {
    api = "http://127.0.0.1:${toString cfg.port}/api";
    inherit (cfg) host;
    inherit (cfg.reconciler) mode;
    skills = { library = cfg.brain.skills; root = skillsRoot; };
    companies = lib.mapAttrs
      (_: c: {
        inherit (c) id name description issuePrefix requireBoardApprovalForNewAgents connections;
        agents = lib.mapAttrs (_: a: removeAttrs a [ "_module" ]) c.agents;
      })
      (lib.filterAttrs (_: c: c.id != null) cfg.companies);
  };

  # Every pass: re-link the library (new and deleted skills reach every client), then wait for
  # the server beside this container and reconcile the declared organisation.
  reconcileLoop = ''
    set -u
    while true; do
      ( set -e
        ${brain.skillsOnly { inherit home; inherit (cfg.brain) skills; }}
      ) || echo "skill links failed" >&2
      until curl -fsS -o /dev/null -H "Host: ${cfg.host}" http://127.0.0.1:${toString cfg.port}/api/health; do sleep 10; done
      python3 ${reconcilerDir}/reconcile.py || echo "reconcile pass reported failures" >&2
      sleep ${toString cfg.reconciler.interval}
    done
  '';

  volumeMounts = lib.listToAttrs
    (map
      (id: lib.nameValuePair "skills-${id}" { name = "brain-skills"; mountPath = "${skillsRoot}/${id}"; })
      companyIds) // {
    home = { name = "home"; mountPath = home; };
    brain = { name = "brain"; mountPath = cfg.brain.root; };
    dotfiles = { name = "dotfiles"; mountPath = dotfilesDir; readOnly = true; };
    tmp = { name = "tmp"; mountPath = "/tmp"; };
  } // lib.optionalAttrs (cfg.nix.hostPath != null) {
    nix = { name = "nix"; mountPath = "/nix"; };
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
      skillsHostPath = mkOption { type = types.str; description = "The same library on the node, bind-mounted as each company's managed-skill directory."; };
      claudeInstructions = mkOption { type = types.nullOr types.lines; default = null; };
      claudeMemoryDir = mkOption { type = types.nullOr types.str; default = null; };
      codexInstructions = mkOption { type = types.nullOr types.lines; default = null; };
    };

    claudeSettings = mkOption { type = types.attrsOf types.anything; default = { }; description = "~/.claude/settings.json"; };
    opencodeConfig = mkOption { type = types.nullOr (types.attrsOf types.anything); default = null; description = "~/.config/opencode/opencode.json"; };
    gitconfig = mkOption { type = types.nullOr types.lines; default = null; };
    clis.grokVersion = mkOption { type = types.nullOr types.str; default = null; description = "Install xAI's @xai-official/grok at this version into the home."; };

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
        description = "Reconciler-only environment from secrets, e.g. connection credentials.";
      };
    };

    companies = mkOption { type = types.attrsOf companyType; default = { }; };
  };

  config = lib.mkIf cfg.enable {
    applications.${cfg.appName} = {
      inherit (cfg) namespace createNamespace project;
      resources = {
        configMaps."${cfg.appName}-dotfiles".data = dotfiles;
        configMaps."${cfg.appName}-reconciler".data = {
          "desired.json" = builtins.toJSON desired;
          "reconcile.py" = builtins.readFile ./reconcile.py;
        };

        deployments.${cfg.appName}.spec = {
          replicas = 1;
          # One server owns the embedded job scheduler and the agent homes.
          strategy.type = "Recreate";
          selector.matchLabels.app = cfg.appName;
          template = {
            metadata.labels.app = cfg.appName;
            # link-home installs the dotfiles only at start, so a change must restart the pod.
            # The organisation is not in this hash: the reconciler rereads it every pass.
            metadata.annotations."checksum/dotfiles" =
              builtins.hashString "sha256" (builtins.toJSON dotfiles + linkHome);
            spec = {
              inherit (cfg) hostname nodeSelector;
              automountServiceAccountToken = false;
              enableServiceLinks = false;
              terminationGracePeriodSeconds = 60;
              securityContext = {
                inherit (cfg) runAsUser runAsGroup;
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              initContainers = lib.optionalAttrs (cfg.nix.hostPath != null)
                {
                  seed-nix = {
                    name = "seed-nix";
                    image = cfg.nix.image;
                    command = [ "sh" "-c" seedNix ];
                    securityContext = containerSecurity;
                    volumeMounts.nix = { name = "nix"; mountPath = "/mnt/nix"; };
                    resources = { requests = { cpu = "50m"; memory = "64Mi"; }; limits.memory = "256Mi"; };
                  };
                } // lib.optionalAttrs (grok != null) {
                install-clis = {
                  name = "install-clis";
                  inherit (cfg) image;
                  command = [ "sh" "-c" installClis ];
                  env.HOME.value = home;
                  securityContext = containerSecurity;
                  volumeMounts = { inherit (volumeMounts) home tmp; };
                  resources = { requests = { cpu = "50m"; memory = "128Mi"; }; limits.memory = "1Gi"; };
                };
              } // {
                link-home = {
                  name = "link-home";
                  inherit (cfg) image;
                  command = [ "sh" "-c" linkHome ];
                  securityContext = containerSecurity;
                  volumeMounts = { inherit (volumeMounts) home brain dotfiles; };
                  resources = { requests = { cpu = "10m"; memory = "16Mi"; }; limits.memory = "64Mi"; };
                };
              };
              containers = {
                ${cfg.appName} = {
                  name = cfg.appName;
                  inherit (cfg) image resources;
                  envFrom = map (name: { secretRef.name = name; }) cfg.secretEnvFrom;
                  env = lib.mapAttrs (_: value: { inherit value; }) ({
                    PAPERCLIP_PUBLIC_URL = "https://${cfg.host}";
                    PAPERCLIP_ALLOWED_HOSTNAMES = cfg.host;
                    PAPERCLIP_DEPLOYMENT_MODE = "authenticated";
                    PAPERCLIP_DEPLOYMENT_EXPOSURE = "private";
                    PAPERCLIP_AUTH_DISABLE_SIGN_UP = lib.boolToString (!cfg.allowSignUp);
                    PAPERCLIP_MIGRATION_AUTO_APPLY = "true";
                    PAPERCLIP_TELEMETRY_DISABLED = "1";
                    DO_NOT_TRACK = "1";
                    DISABLE_AUTOUPDATER = "1";
                    PATH = path;
                  } // lib.optionalAttrs (cfg.nix.hostPath != null) {
                    NIX_CONFIG = cfg.nix.config;
                    NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
                  } // cfg.env);
                  ports.http = { name = "http"; containerPort = cfg.port; };
                  startupProbe = { httpGet = { path = "/api/health"; port = "http"; httpHeaders = healthHeaders; }; periodSeconds = 5; failureThreshold = 120; };
                  readinessProbe = { httpGet = { path = "/api/health"; port = "http"; httpHeaders = healthHeaders; }; periodSeconds = 10; };
                  livenessProbe = { httpGet = { path = "/api/health"; port = "http"; httpHeaders = healthHeaders; }; periodSeconds = 30; timeoutSeconds = 5; failureThreshold = 5; };
                  securityContext = containerSecurity;
                  inherit volumeMounts;
                };
              } // lib.optionalAttrs cfg.reconciler.enable {
                # Its own container so the board key never reaches the agents' environment.
                reconciler = {
                  name = "reconciler";
                  inherit (cfg) image;
                  command = [ "sh" "-c" reconcileLoop ];
                  env = {
                    PAPERCLIP_BOARD_TOKEN.valueFrom.secretKeyRef = { inherit (cfg.reconciler.boardSecret) name key; };
                    NIXAGENT_PAPERCLIP_DESIRED.value = "${reconcilerDir}/desired.json";
                  } // lib.mapAttrs (_: s: { valueFrom.secretKeyRef = { inherit (s) name key; }; }) cfg.reconciler.secretEnv;
                  securityContext = containerSecurity;
                  volumeMounts = { inherit (volumeMounts) home brain tmp; } // {
                    reconciler = { name = "reconciler"; mountPath = reconcilerDir; readOnly = true; };
                  };
                  resources = { requests = { cpu = "5m"; memory = "32Mi"; }; limits.memory = "128Mi"; };
                };
              };
              volumes = {
                home = { name = "home"; hostPath = { path = cfg.home.hostPath; type = "Directory"; }; };
                brain = { name = "brain"; hostPath = { path = cfg.brain.hostPath; type = "Directory"; }; };
                brain-skills = { name = "brain-skills"; hostPath = { path = cfg.brain.skillsHostPath; type = "Directory"; }; };
                dotfiles = { name = "dotfiles"; configMap.name = "${cfg.appName}-dotfiles"; };
                reconciler = { name = "reconciler"; configMap.name = "${cfg.appName}-reconciler"; };
                tmp = { name = "tmp"; emptyDir.sizeLimit = "8Gi"; };
              } // lib.optionalAttrs (cfg.nix.hostPath != null) {
                nix = { name = "nix"; hostPath = { path = cfg.nix.hostPath; type = "Directory"; }; };
              };
            } // lib.optionalAttrs (cfg.priorityClassName != null) { inherit (cfg) priorityClassName; };
          };
        };

        services.${cfg.appName}.spec = {
          type = "ClusterIP";
          selector.app = cfg.appName;
          ports.http = { name = "http"; inherit (cfg) port; targetPort = "http"; };
        } // lib.optionalAttrs (cfg.clusterIP != null) { inherit (cfg) clusterIP; };
      };
    };
  };
}
