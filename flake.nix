# SPDX-License-Identifier: MIT OR Apache-2.0
{
  description = "nixagent — agentic AI clients (Claude, Codex, DeepSeek Harness, Gemini, Grok Build, Qwen Code, opencode, omp, and desktop clients), declared per host and delivered from pacman/AUR or the vendor's own mutable path, never nixpkgs";

  # NO INPUTS FOR CONSUMERS, same reasoning nixmsg and nixdev state for themselves: this flake is
  # options plus a catalogue, taking `pkgs`/`config`/`lib` from whichever evaluation composes it,
  # so a real host never puts a second nixpkgs -- or a sibling flake's whole input closure -- in
  # its own closure.
  inputs = {
    # checks-only. Nothing this flake EXPORTS reaches into it, and the exported module never
    # installs a nixpkgs derivation at all (see modules/nixagent.nix's header: there is no NixOS
    # backend here, on purpose), so this input exists purely to give `nix flake check` a `lib` and
    # a derivation shell to hang the eval-time assertions on.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # nixidy renders modules/paperclip to Argo CD manifests. A real input, not just a name in a
    # comment: without it there is no module system to render `nixidyModules.paperclip` against,
    # and the render check would pass by checking nothing. Consumers make it follow their own.
    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixidy }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      # Arch / system-manager: the policy module IS the backend, exactly as in nixmsg. Nothing
      # platform-specific is left to do on this plane -- the lists are published for the host's
      # own pacman reconciler to consume, and a second file that only re-exported this one would
      # be an indirection rather than a backend. See modules/nixagent.nix's own header.
      systemManagerModules.nixagent = ./modules/nixagent.nix;
      systemManagerModules.default = ./modules/nixagent.nix;

      # cfetch — the memory/retrieval brain the catalogued clients consult. Beside the catalogue,
      # not in it: it does not self-update, so the never-nixpkgs rule that defines the catalogue
      # does not bind it (its NixOS plane is its own flake, github:corbet-labs/cfetch). The
      # system plane publishes its AUR name; the home plane owns config/daemon/registration.
      # See modules/cfetch.nix's header for the full boundary argument.
      systemManagerModules.cfetch = ./modules/cfetch.nix;

      # Home-manager: the UPSTREAM delivery mode. Uses each selected tool's vendor-supported
      # mutable path (shell installer or the documented npx dispatch) and puts it on PATH -- nix
      # ensures the command exists and never owns the client payload. This is how a NixOS host gets these tools, and how ANY host gets
      # one whose distro package has fallen behind (measured: the AUR carried omp 17.2.2/17.2.3
      # against an upstream 17.2.12 on 2026-08-10, both flagged out of date). Independent of the
      # system plane above: a consumer picks per host, and neither is forced.
      homeManagerModules.cfetch = ./modules/cfetch-home.nix;
      # The brain: one shared knowledge store -- above all ONE skill library -- wired into every
      # agent client of a home. `lib.brain` carries the same snippets for containers without
      # home-manager (an agent-orchestration pod). See lib/brain.nix and modules/brain-home.nix.
      homeManagerModules.brain = ./modules/brain-home.nix;

      # A Paperclip agent company, declared: the server's deployment wired to the same brain as
      # every host, and its organisation (companies, agents, connections) kept by a reconciler.
      # See modules/paperclip/default.nix.
      nixidyModules.paperclip = ./modules/paperclip;
      homeManagerModules.nixagent = ./modules/home.nix;
      homeManagerModules.home = ./modules/home.nix;
      homeManagerModules.default = ./modules/home.nix;

      # STILL NO `nixosModules` OUTPUT, DELIBERATELY, and the home-manager plane above is not a
      # step towards one -- it is the reason one is still not needed. Every catalogue entry is
      # `nixpkgs = null` by policy: these tools ship their own updater, which a read-only store
      # path cannot run, and nixpkgs measurably lags every one of them (lib/agents.nix's header
      # carries the numbers). A `nixosModules` output could only mean `environment.systemPackages`
      # of exactly those frozen derivations. A NixOS host that wants these tools composes
      # `homeManagerModules.nixagent` instead, which installs the vendor's own build and leaves
      # its updater working. The absence is the repo's boundary, not an unfinished corner.

      # Policy alone, for a consumer that wants the computed lists and will wire them itself, plus
      # the raw catalogue for inspection without re-reading the file. Same split as nixsh's own
      # `lib.policy`/`lib.catalogue` pair.
      lib.policy = ./modules/nixagent.nix;
      lib.catalogue = import ./lib/agents.nix { };
      lib.brain = import ./lib/brain.nix;

      # `nix flake check` does not evaluate `systemManagerModules` or `homeManagerModules` on its
      # own, so a green check on this repo without these files would cover nothing but flake
      # syntax. Each file's own header states what is under test and what deliberately is not.
      #
      # `upstream-install` is the odd one out and the important one: it is not an eval-time
      # assertion but a RUN of lib/install-upstream.sh against a stubbed curl, because a delivery
      # mode whose idempotency and failure behaviour are only asserted on paper is a delivery mode
      # nobody can trust. Note that it therefore does real work only under a plain `nix flake
      # check`; `--no-build` evaluates it and stops.
      checks = forAllSystems (system: {
        agents-eval = import ./checks/agents-eval.nix { pkgs = pkgsFor system; };
        cfetch-home-eval = import ./checks/cfetch-home-eval.nix { pkgs = pkgsFor system; };
        brain-links = import ./checks/brain-links.nix { pkgs = pkgsFor system; };
        brain-home-eval = import ./checks/brain-home-eval.nix { pkgs = pkgsFor system; };
        # The reconciler at least compiles and its manager-first ordering holds; driving it
        # against a live Paperclip is the consumer's report-mode pass.
        paperclip-reconciler = (pkgsFor system).runCommand "nixagent-paperclip-reconciler"
          { nativeBuildInputs = [ (pkgsFor system).python3 ]; } ''
          cp ${./modules/paperclip/reconcile.py} reconcile.py
          python3 -m py_compile reconcile.py
          echo '{"api":"x","host":"x","mode":"report","skills":{},"companies":{}}' > desired.json
          NIXAGENT_PAPERCLIP_DESIRED=desired.json PAPERCLIP_BOARD_TOKEN=x python3 -c '
          import reconcile as r
          order = r.ordered_agents({"c": {"reportsTo": "b"}, "b": {"reportsTo": "a"}, "a": {}})
          assert order == ["a", "b", "c"], order
          try:
              r.ordered_agents({"a": {"reportsTo": "b"}, "b": {"reportsTo": "a"}})
              raise SystemExit("cycle not detected")
          except RuntimeError:
              pass
          '
          echo ok > $out
        '';
        # Renders modules/paperclip against the real module system from examples/paperclip.
        paperclip-renders = (nixidy.lib.mkEnv {
          pkgs = pkgsFor system;
          modules = [ ./modules/paperclip ./examples/paperclip/values.nix ];
        }).environmentPackage;
        home-eval = import ./checks/home-eval.nix { pkgs = pkgsFor system; };
        upstream-install = import ./checks/upstream-install.nix { pkgs = pkgsFor system; };
      });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
