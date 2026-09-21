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
  };

  outputs = { self, nixpkgs }:
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
        home-eval = import ./checks/home-eval.nix { pkgs = pkgsFor system; };
        upstream-install = import ./checks/upstream-install.nix { pkgs = pkgsFor system; };
      });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
