# SPDX-License-Identifier: MIT OR Apache-2.0
#
# nixagent's policy module: the selection surface, the catalogue resolution, and the package-name
# lists a host's own reconciler consumes. Installs nothing itself.
#
# THIS MODULE IS ALSO THE ARCH BACKEND, and there is deliberately no second file behind
# `systemManagerModules.default`. Same conclusion nixmsg reached for itself once its one
# platform-specific job moved elsewhere: on Arch there is no installer here to call, so an
# `arch.nix` whose entire body was `imports = [ ./nixagent.nix ];` would be a file that exists to
# be an indirection. The lists below are published; the host wires them:
#
#   nixarch.packages.pacman = config.nixagent.archPackages
#                              ++ config.nixagent.runtimeArchPackages;
#   nixarch.packages.aur    = config.nixagent.aurPackages;
#
# PUBLISHED, NOT WIRED, and that is a choice rather than an omission. This module could assign
# `nixarch.packages.*` directly (nixremote's own system-manager plane does exactly that for its
# install flags). It does not, for the reason nixsh/nixmsg/nixllm all also do not: a host almost
# always concatenates several catalogues into one reconciler list, and a module that assigns into
# a FOREIGN namespace both hard-depends on that namespace existing and takes the concatenation
# point away from the one file that can see all the catalogues at once.
#
# THERE IS NO NixOS BACKEND, AND THERE WILL NOT BE. Every catalogue entry carries `nixpkgs = null`
# by policy -- these tools self-update and nixpkgs lags them, both measured, see ../lib/agents.nix's
# own header for the numbers. So there is no `nixosPackages` option here and no `nixosModules`
# output in the flake: not a gap to fill later, but the boundary this repo was drawn for. A NixOS
# host that composes this module gets options it can set and lists nothing reads, which is the
# honest outcome -- better than an `environment.systemPackages` path that would silently install
# the frozen copy this repo exists to refuse.
#
# ONE NAMESPACE. Everything declared here lives under `nixagent`, like every repo in this family.
{ config, lib, ... }:
let
  cfg = config.nixagent;
  cat = import ../lib/agents.nix { };

  mkGroup = what: table: lib.mkOption {
    type = lib.types.listOf (lib.types.enum (lib.attrNames table));
    default = [ ];
    description = "Which ${what}. Available: ${lib.concatStringsSep ", " (lib.attrNames table)}.";
  };

  # Groups are hand-listed here rather than generated from `lib.attrNames cat`, matching nixsh's
  # own modules/tools.nix. The fragility that invites -- a group added to the catalogue and never
  # wired into an option -- is closed by a check instead of by cleverness: checks/agents-eval.nix
  # asserts that every catalogue group has a matching option on this module.
  # Each resolved entry carries its own catalogue KEY back out as `name`, the way nixmsg's own
  # `resolveApp` does -- without it, everything downstream that needs to say WHICH selection a
  # resolved attrset came from would have to re-derive it by matching on `arch`, which is a
  # different string for most of this catalogue.
  resolve = table: k: table.${k} // { name = k; };

  selected = lib.flatten [
    (map (resolve cat.cli) cfg.cli)
    (map (resolve cat.desktop) cfg.desktop)
  ];

  # An entry is AUR *for this host* unless the host's distro is one whose own repositories carry
  # it -- see `archRepoOn` in ../lib/agents.nix. Deliberately resolved HERE rather than in the
  # catalogue: which repositories a name is in is a fact about the world (catalogue), which of
  # them this machine can reach is a fact about the machine (config).
  fromAur = t: (t.aur or false) && !(lib.elem cfg.distro (t.archRepoOn or [ ]));

  # A derivative can publish the same upstream application under a different package name. The
  # plain-Arch/AUR name remains `arch`, the safe floor; `archPackageOn` changes only the emitted
  # name on the explicitly named derivative. ChatGPT Desktop is the real case: the AUR calls the
  # package `chatgpt-desktop`, while CachyOS calls its repository package `chatgpt-desktop-bin`.
  packageName = t: (t.archPackageOn or { }).${cfg.distro} or t.arch;
in
{
  options.nixagent = {
    cli = mkGroup "agentic AI CLIs -- terminal clients driving a remote frontier model (see ../lib/agents.nix's own header for the boundary against nixllm, which serves models, and nixsh, which is universal)" cat.cli;

    desktop = mkGroup "desktop AI clients -- graphical applications driving a remote frontier model, with the same delivery boundary as \`cli\` and a separate group so \`cli\` keeps meaning terminal clients (see ../lib/agents.nix's own header)" cat.desktop;

    distro = lib.mkOption {
      type = lib.types.enum [ "arch" "cachyos" ];
      default = "arch";
      description = ''
        Which Arch-family distribution this host runs. Read for ONE purpose: deciding whether a
        catalogue entry that is AUR-only upstream can come from a derivative's own repository
        instead (`archRepoOn` in lib/agents.nix).

        Defaults to "arch", the FLOOR rather than the common case, because the two answers fail
        differently. Declaring "arch" on a CachyOS host costs a package a trip through the AUR
        helper, which then finds it in a repository anyway -- an AUR helper resolves repository
        packages first, so nothing is built from source that did not need to be. Declaring
        "cachyos" on a plain Arch host puts a name pacman cannot resolve into the pacman list, and
        `pacman -S` fails a transaction ATOMICALLY: one unresolvable target aborts the whole
        converge with "target not found" and takes every unrelated package in it down. A default
        can only be wrong in one of those directions, so it is wrong in the recoverable one.

        Declared, never probed -- same reasoning nixarch states for its own identically-valued
        `nixarch.packages.distro`: this module is evaluated wherever the flake is built, which is
        not necessarily the machine it targets, so eval-time detection would as often as not read
        the wrong host's identity. Set it to match the box, alongside whatever the host already
        tells nixarch.
      '';
    };

    # ── Computed, read-only ─────────────────────────────────────────────────────────────────────
    selected = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      internal = true;
      description = ''
        The resolved catalogue entries for every name selected above, in one flat list -- the
        canonical "what did this host actually ask for" that everything else here derives from.
      '';
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections that come from an official repository THIS host can reach, as pacman names.
        For the host's own reconciler:

          nixarch.packages.pacman = config.nixagent.archPackages;

        Membership depends on `nixagent.distro` for any entry with an `archRepoOn` -- see that
        option, and lib/agents.nix's `claude-code` entry.
      '';
    };

    runtimeArchPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Official-repository runtime prerequisites of the selected clients, as pacman names.
        Kept separate from `archPackages` because these are the ground a client runs on, not
        additional client selections. Feed both lists to the host reconciler:

          nixarch.packages.pacman =
            config.nixagent.archPackages ++ config.nixagent.runtimeArchPackages;

        Currently this is `bubblewrap` when `openai-codex` is selected. Codex's Linux sandbox
        uses the first `bwrap` on PATH and documents the distribution package as the reliable
        prerequisite; the bundled helper is only a fallback.
      '';
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections that must be built from the AUR on this host, kept SEPARATE from
        `archPackages` because `pacman -S` cannot resolve an AUR name: it fails the whole
        transaction with "target not found", taking every other package in the same converge with
        it. Wire to the AUR side of the same reconciler:

          nixarch.packages.aur = config.nixagent.aurPackages;

        Non-empty means the host needs a working AUR helper (and, for an unattended reconciler,
        whatever non-root user and sudo rule that helper requires). If it has neither, prefer
        leaving the selection out over declaring something that will be reported as installed and
        will not exist.
      '';
    };

    binaries = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = ''
        catalogue name -> the command actually installed, for every selection. Published because
        the two disagree for most of this catalogue (`openai-codex` installs `codex`,
        `claude-code` installs `claude`), and a consumer writing a wrapper, an alias, a launcher
        or a home-manager config against the PACKAGE name gets a command that does not exist.
      '';
    };
  };

  config = {
    nixagent.selected = selected;
    nixagent.archPackages = lib.unique (map packageName (lib.filter (t: !(fromAur t)) selected));
    nixagent.aurPackages = lib.unique (map packageName (lib.filter fromAur selected));
    nixagent.runtimeArchPackages = lib.unique
      (lib.concatMap (t: (t.runtime or { archPackages = [ ]; }).archPackages) selected);
    # Derived from `selected`, not from `cfg.cli` -- so a future group needs no edit here beyond
    # the one line in `selected` above.
    nixagent.binaries =
      lib.listToAttrs (map (t: lib.nameValuePair t.name t.binary) selected);
  };
}
