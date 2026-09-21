# SPDX-License-Identifier: MIT OR Apache-2.0
# Evaluates modules/nixagent.nix for real against `lib.evalModules` and asserts what it resolves --
# the same "Nix inspecting Nix" tier as nixsh's checks/tools-eval.nix, and here for the same reason
# that file states: `nix flake check` does NOT evaluate `systemManagerModules` on its own, so a
# green check on this repo without a file like this one would prove nothing but flake syntax.
#
# Deliberately pkgs-FREE beyond `pkgs.emptyFile` for the derivation shell. Every question this
# repo can actually answer at eval time is a question about NAMES and LISTS -- which group a key
# belongs to, which side of the pacman/AUR split a name lands on for a given distro, whether the
# nixpkgs prohibition still holds -- and none of them needs a package set. Unlike its siblings this
# repo has no nixpkgs-resolution half to check at all: `nixpkgs = null` everywhere is the policy,
# and asserting THAT is one of the checks below rather than something a real `pkgs` would help with.
#
# SCOPE, now that there are two delivery modes. This file owns the SYSTEM plane
# (../modules/nixagent.nix: the pacman/AUR split) plus every assertion about the CATALOGUE itself,
# including the shape of the `upstream` field the second mode reads. How that field resolves into
# a home-manager activation is ./home-eval.nix, and whether the resulting script actually behaves
# is ./upstream-install.nix -- which runs it rather than asserting about it.
#
# What can NOT be proven here, and is not pretended: whether `claude-code` is in a given
# repository today, or whether an installer URL still answers. Those are facts about the world,
# they change without this repo changing, and they are verified out of band against live sources
# -- see ../experiments/verify-package-names.sh.
{ pkgs, lib ? pkgs.lib }:
let
  cat = import ../lib/agents.nix { };

  evalWith = selection: (lib.evalModules {
    modules = [ ../modules/nixagent.nix { nixagent = selection; } ];
  }).config.nixagent;

  allClients = lib.attrNames cat.cli;
  allDesktop = lib.attrNames cat.desktop;
  allSelectable = lib.length allClients + lib.length allDesktop;

  # The whole catalogue, on each of the two distro answers. Both fixtures matter: the arch/AUR
  # split is not a property of the catalogue alone here, it is a property of the catalogue AND the
  # host, so a check that only ever evaluated one of them would leave half the resolution untested.
  # Both groups selected together -- `cli` and `desktop` share one `selected` list, and a fixture
  # that only ever populated one group would leave the other's contribution to the shared
  # archPackages/aurPackages split untested.
  archAll = evalWith { cli = allClients; desktop = allDesktop; distro = "arch"; };
  cachyAll = evalWith { cli = allClients; desktop = allDesktop; distro = "cachyos"; };

  empty = evalWith { };
  codexOnly = evalWith { cli = [ "openai-codex" ]; };
  deepseekOnly = evalWith { cli = [ "deepseek-harness" ]; };
  opencodeOnly = evalWith { cli = [ "opencode" ]; };

  has = list: item: lib.elem item list;
  sorted = lib.sort (a: b: a < b);

  # Every entry in the catalogue, group-blind. The `upstream` assertions below are properties of
  # an ENTRY rather than of a group, and ../modules/home.nix flattens the groups the same way.
  allEntries = lib.concatMap (g: lib.attrValues cat.${g}) (lib.attrNames cat);
  allKeys = lib.concatMap (g: lib.attrNames cat.${g}) (lib.attrNames cat);
  withUpstream = lib.filter (t: t.upstream != null) allEntries;

  results = {
    # ── The floor: nothing selected must produce nothing at all ────────────────────────────────
    "empty selection resolves to nothing selected" =
      empty.selected == [ ];

    "empty selection produces empty package lists on BOTH sides and no runtime packages, not one populated by default" =
      empty.archPackages == [ ]
      && empty.aurPackages == [ ]
      && empty.runtimeArchPackages == [ ]
      && empty.binaries == { };

    # ── THE LOAD-BEARING INVARIANT ────────────────────────────────────────────────────────────
    # One AUR name reaching a pacman list aborts the entire pacman transaction ("target not
    # found") and takes every unrelated package in the same converge down with it. Asserted on
    # both distro answers, because that is exactly where an entry can move between the lists.
    "archPackages and aurPackages never intersect -- the whole-transaction abort this split exists to prevent (distro = arch)" =
      lib.intersectLists archAll.archPackages archAll.aurPackages == [ ];

    "archPackages and aurPackages never intersect (distro = cachyos)" =
      lib.intersectLists cachyAll.archPackages cachyAll.aurPackages == [ ];

    "every selection lands on exactly one of the two lists -- none silently dropped, none counted twice (both distros)" =
      lib.length (archAll.archPackages ++ archAll.aurPackages) == allSelectable
      && lib.length (cachyAll.archPackages ++ cachyAll.aurPackages) == allSelectable;

    # ── Group wiring ──────────────────────────────────────────────────────────────────────────
    # Hand-listed groups in modules/nixagent.nix are cheap and readable; the failure they invite
    # is a catalogue group that never gets an option. This closes it: adding a group to
    # lib/agents.nix without wiring it fails the check rather than resolving to nothing forever.
    "every catalogue group has a matching selection option on the module" =
      lib.all (g: (evalWith { }) ? ${g}) (lib.attrNames cat);

    "every group contributes to \`selected\` -- selecting the whole catalogue resolves every entry (cli: 9, desktop: 3, total: 12)" =
      lib.length archAll.selected == 12
      && lib.length archAll.selected == allSelectable;

    "each group's option is typed to its OWN keys -- a name from another group (or a typo) is refused at eval time, not silently ignored" =
      # `evalModules` is lazy: `tryEval` alone forces only WHNF (the attrset exists), never the
      # type-checked value inside. `deepSeq` forces through, which is what actually runs the
      # listOf-enum merge that rejects the name.
      (builtins.tryEval (builtins.deepSeq (evalWith { cli = [ "lmstudio-bin" ]; }).cli true)).success == false;

    "the \`desktop\` option is typed to its OWN keys too -- a \`cli\` name is refused as a desktop selection" =
      (builtins.tryEval (builtins.deepSeq (evalWith { desktop = [ "claude-code" ]; }).desktop true)).success == false;

    # ── THE REPO'S REASON TO EXIST, MECHANISED ────────────────────────────────────────────────
    # These tools self-update and nixpkgs lags them (measured -- see lib/agents.nix's header), so
    # the catalogue installs from pacman/AUR and never from nixpkgs. Asserted over the RAW
    # catalogue rather than a selection, so an entry that is not yet selectable anywhere is still
    # covered the moment it is written.
    "every catalogue entry carries nixpkgs = null -- the AUR/pacman-never-nixpkgs policy, enforced rather than merely documented" =
      lib.all (t: t ? nixpkgs && t.nixpkgs == null)
        (lib.concatMap (g: lib.attrValues cat.${g}) (lib.attrNames cat));

    "the module publishes no nixpkgs-facing option at all -- no nixosPackages, no unavailableOnNixos; there is no NixOS backend to feed and a half-built one would be worse than none" =
      let o = evalWith { }; in
      !(o ? nixosPackages) && !(o ? unavailableOnNixos) && !(o ? nixpkgsPackages);

    # ── The distro-dependent entry ────────────────────────────────────────────────────────────
    # Several clients are in no upstream Arch repository but are in both the AUR and CachyOS's own
    # repo. Pin each distro-dependent result so a future edit cannot quietly put an AUR-only name
    # into pacman's transaction.
    "claude-code is AUR on plain Arch -- the safe floor, since upstream Arch packages it nowhere" =
      has archAll.aurPackages "claude-code" && !(has archAll.archPackages "claude-code");

    "claude-code moves to the pacman list on a distro whose own repository carries it" =
      has cachyAll.archPackages "claude-code" && !(has cachyAll.aurPackages "claude-code");

    "the default distro is the recoverable one: a host that declares nothing gets claude-code from the AUR, never a pacman target that may not resolve" =
      let d = evalWith { cli = [ "claude-code" ]; }; in
      d.aurPackages == [ "claude-code" ] && d.archPackages == [ ];

    "claude-desktop is AUR on plain Arch and moves to the CachyOS repository under the same package name" =
      has archAll.aurPackages "claude-desktop" && !(has archAll.archPackages "claude-desktop")
      && has cachyAll.archPackages "claude-desktop" && !(has cachyAll.aurPackages "claude-desktop");

    "ChatGPT Desktop uses the AUR name on plain Arch and the distinct CachyOS repository name on CachyOS" =
      has archAll.aurPackages "chatgpt-desktop"
      && !(has archAll.archPackages "chatgpt-desktop")
      && !(has (archAll.archPackages ++ archAll.aurPackages) "chatgpt-desktop-bin")
      && has cachyAll.archPackages "chatgpt-desktop-bin"
      && !(has cachyAll.aurPackages "chatgpt-desktop-bin")
      && !(has (cachyAll.archPackages ++ cachyAll.aurPackages) "chatgpt-desktop");

    "repository lifts are scoped to their entries; DeepSeek Harness, grok-build, muse-code and omp remain AUR on CachyOS" =
      sorted cachyAll.aurPackages == [ "deepseek-harness-bin" "grok-build" "muse-code-bin" "oh-my-pi-bin" "opencode-desktop-bin" ]
      && sorted archAll.aurPackages == [ "chatgpt-desktop" "claude-code" "claude-desktop" "deepseek-harness-bin" "grok-build" "muse-code-bin" "oh-my-pi-bin" "opencode-desktop-bin" ];

    "DeepSeek Harness uses the current AUR binary package on both distros and publishes dsh, not its package name" =
      has archAll.aurPackages "deepseek-harness-bin"
      && has cachyAll.aurPackages "deepseek-harness-bin"
      && archAll.binaries.deepseek-harness == "dsh";

    "opencode-desktop is AUR on every distro under its PACKAGE name, and publishes the opencode-desktop command" =
      has archAll.aurPackages "opencode-desktop-bin" && has cachyAll.aurPackages "opencode-desktop-bin"
      && !(has archAll.archPackages "opencode-desktop-bin") && !(has cachyAll.archPackages "opencode-desktop-bin")
      && archAll.binaries.opencode-desktop == "opencode-desktop";

    "grok-build is AUR on every distro and publishes its actual grok command" =
      has archAll.aurPackages "grok-build" && has cachyAll.aurPackages "grok-build"
      && archAll.binaries.grok-build == "grok";

    "muse-code is AUR on every distro under its PACKAGE name, and publishes the muse command" =
      has archAll.aurPackages "muse-code-bin" && has cachyAll.aurPackages "muse-code-bin"
      && !(has archAll.archPackages "muse-code-bin") && !(has cachyAll.archPackages "muse-code-bin")
      && !(has (archAll.archPackages ++ archAll.aurPackages) "muse-code")
      && archAll.binaries.muse-code == "muse"
      && cat.cli.muse-code.arch == "muse-code-bin";

    # omp is in no upstream Arch repository and in no derivative's repository either (all three of
    # `oh-my-pi-bin`, `oh-my-pi` and `omp` checked 2026-08-10 -- see its catalogue entry), so it
    # carries no `archRepoOn` and must stay on the AUR list whatever the host says it runs. Pinned
    # separately because a future `archRepoOn` would silently move it to the wrong transaction.
    "omp is AUR on EVERY distro, under its PACKAGE name -- the key `omp` is the tool, `oh-my-pi-bin` is the package, and only the latter may reach a package list" =
      has archAll.aurPackages "oh-my-pi-bin" && has cachyAll.aurPackages "oh-my-pi-bin"
      && !(has archAll.archPackages "oh-my-pi-bin") && !(has cachyAll.archPackages "oh-my-pi-bin")
      && !(has (archAll.archPackages ++ archAll.aurPackages) "omp")
      && !(has (archAll.archPackages ++ archAll.aurPackages) "oh-my-pi");

    "the four upstream-Arch entries stay on the pacman list regardless of distro -- their repository membership is not derivative-dependent" =
      lib.all (n: has archAll.archPackages n && has cachyAll.archPackages n)
        [ "gemini-cli" "openai-codex" "opencode" "qwen-code" ];

    # ── Package name vs command name ──────────────────────────────────────────────────────────
    # Several disagree. A consumer aliasing, wrapping or launching by the PACKAGE name
    # gets a command that does not exist, which is what `binaries` is published to prevent.
    "binaries maps every selection to its real command, not its package name" =
      archAll.binaries == {
        claude-code = "claude";
        deepseek-harness = "dsh";
        gemini-cli = "gemini";
        grok-build = "grok";
        muse-code = "muse";
        openai-codex = "codex";
        opencode = "opencode";
        omp = "omp";
        qwen-code = "qwen";
        chatgpt-desktop = "chatgpt";
        claude-desktop = "claude-desktop";
        opencode-desktop = "opencode-desktop";
      };

    # omp is the sharpest case in the catalogue: catalogue key `omp`, pacman name `oh-my-pi-bin`,
    # npm name `@oh-my-pi/pi-coding-agent`, command `omp`. It is also the entry that broke the
    # coincidence that every key equalled its `arch` value -- see lib/agents.nix's own section on
    # why the key names the TOOL rather than one delivery mode's package.
    "the omp key/package/command divergence is pinned -- the key is not the package name, and the package name is not the command" =
      archAll.binaries.omp == "omp"
      && has archAll.aurPackages "oh-my-pi-bin"
      && (cat.cli.omp.arch == "oh-my-pi-bin");

    "the codex package/command divergence is pinned in both directions -- the pacman name is openai-codex, the command is codex, and neither is usable in the other's place" =
      has archAll.archPackages "openai-codex"
      && !(has archAll.archPackages "codex")
      && archAll.binaries.openai-codex == "codex";

    # Codex's Linux sandbox uses the first `bwrap` on PATH. The bundled helper is only a fallback;
    # the vendor documents the distribution package as the reliable prerequisite. Keep it separate
    # from `archPackages`: one is the selected client, the other is ground that client runs on.
    "selecting codex publishes bubblewrap as its Arch runtime prerequisite, exactly once" =
      codexOnly.runtimeArchPackages == [ "bubblewrap" ]
      && codexOnly.archPackages == [ "openai-codex" ]
      && !(has codexOnly.archPackages "bubblewrap");

    "Arch runtime additions are conditional on codex; DeepSeek's AUR package already declares its Node runtime" =
      opencodeOnly.runtimeArchPackages == [ ]
      && deepseekOnly.runtimeArchPackages == [ ];

    "binaries covers exactly the selection, no more -- an unselected entry contributes no command" =
      let d = evalWith { cli = [ "opencode" ]; }; in
      d.binaries == { opencode = "opencode"; };

    # ── Catalogue integrity ───────────────────────────────────────────────────────────────────
    "every catalogue entry names both a package and a command -- a missing `binary` would make `nixagent.binaries` silently wrong rather than absent" =
      lib.all (t: t ? arch && t ? binary && lib.isString t.arch && lib.isString t.binary)
        (lib.concatMap (g: lib.attrValues cat.${g}) (lib.attrNames cat));

    "runtime package metadata is string lists on both supported Linux delivery planes" =
      lib.all
        (t:
          let runtime = t.runtime or { archPackages = [ ]; nixpkgsPackages = [ ]; }; in
          lib.isList runtime.archPackages
          && lib.all lib.isString runtime.archPackages
          && lib.isList runtime.nixpkgsPackages
          && lib.all lib.isString runtime.nixpkgsPackages)
        allEntries;

    "codex declares bubblewrap on both Linux delivery planes and DeepSeek declares its NixOS-only Node runtime" =
      cat.cli.openai-codex.runtime == {
        archPackages = [ "bubblewrap" ];
        nixpkgsPackages = [ "bubblewrap" ];
      }
      && cat.cli.deepseek-harness.runtime == {
        archPackages = [ ];
        nixpkgsPackages = [ "nodejs" "pnpm" ];
      }
      && lib.all (t: !(t ? runtime))
        (lib.filter (t: t.binary != "codex" && t.binary != "dsh") allEntries);

    "`archRepoOn` only ever appears on an entry that is AUR-only upstream -- on an official-repo entry it would be a no-op that reads like a promise" =
      lib.all (t: !(t ? archRepoOn) || (t.aur or false))
        (lib.concatMap (g: lib.attrValues cat.${g}) (lib.attrNames cat));

    "every `archRepoOn` names a distro `nixagent.distro` can actually be set to -- a typo'd derivative would silently never match" =
      lib.all (d: lib.elem d [ "arch" "cachyos" ])
        (lib.concatMap (t: t.archRepoOn or [ ])
          (lib.concatMap (g: lib.attrValues cat.${g}) (lib.attrNames cat)));

    "every `archPackageOn` override names a supported distro whose repository is explicitly selected for that entry" =
      lib.all
        (t:
          lib.all
            (d: lib.elem d [ "arch" "cachyos" ] && lib.elem d (t.archRepoOn or [ ]))
            (lib.attrNames (t.archPackageOn or { })))
        allEntries;

    "ChatGPT Desktop is the one measured cross-distro package-name override" =
      cat.desktop.chatgpt-desktop.arch == "chatgpt-desktop"
      && cat.desktop.chatgpt-desktop.archPackageOn == { cachyos = "chatgpt-desktop-bin"; }
      && lib.all (t: !(t ? archPackageOn))
        (lib.filter (t: t.binary != "chatgpt") allEntries);

    # ── The SECOND delivery mode's catalogue half ─────────────────────────────────────────────
    # ../modules/home.nix runs the delivery method selected by `upstream.kind` and then probes
    # `upstream.installs`. Every one of those values reaches a shell or a filesystem
    # test at activation time on a real machine, so the shape is asserted here where a typo costs
    # a failed `nix flake check` rather than a failed switch on three hosts.

    "every catalogue entry carries an `upstream` field -- null where the vendor ships no delivery path, so a blank cannot be mistaken for an unresearched entry" =
      lib.all (t: t ? upstream) allEntries;

    "every non-null `upstream` names one supported delivery kind and an installed command path" =
      lib.all
        (t:
          lib.elem t.upstream.kind [ "installer" "npx" ]
          && lib.isString t.upstream.installs)
        withUpstream;

    "installer entries carry an HTTPS script/runner/args tuple; the npx entry carries an unversioned official package spec instead" =
      lib.all
        (t:
          if t.upstream.kind == "installer" then
            lib.isString t.upstream.url
            && lib.hasPrefix "https://" t.upstream.url
            && lib.elem t.upstream.runner [ "bash" "sh" ]
            && lib.isList t.upstream.args
            && lib.all lib.isString t.upstream.args
            && !(t.upstream ? package)
          else
            t.upstream.kind == "npx"
            && t.upstream.package == "@deepseek-ai/dsh"
            && !(t.upstream ? url)
            && !(t.upstream ? runner)
            && !(t.upstream ? args))
        withUpstream;

    # The loader preflight is gated on this and nothing else, so a missing field would read as
    # `null` -> falsy -> "needs no loader", silently disarming the preflight for an entry that does.
    # Asserted as a real bool rather than merely present, for the same reason.
    "every non-null `upstream` states its loader requirement as a bool -- an absent field would silently disarm the preflight" =
      lib.all (t: t.upstream ? needsDynamicLoader && lib.isBool t.upstream.needsDynamicLoader)
        withUpstream;

    # Renamed from `nativeBinary` on 2026-08-11 because codex is a static-PIE musl binary that
    # needs no loader: the field is about the REQUIREMENT, not the artifact. Pinned so a revert to
    # the old name -- which would evaluate to null and disarm the check above -- cannot land quietly.
    "no entry carries the retired `nativeBinary` name, which named the artifact rather than the host requirement" =
      lib.all (t: t.upstream == null || !(t.upstream ? nativeBinary)) allEntries;

    # `env` reaches `env NAME=VALUE` in a shell. A non-string value, or a name that is not a legal
    # identifier, becomes a command to execute rather than an assignment.
    "every `upstream.env` is a string->string attrset with identifier-shaped names" =
      lib.all
        (t:
          let e = t.upstream.env or { }; in
          lib.isAttrs e
          && lib.all (n: lib.isString e.${n} && builtins.match "[A-Za-z_][A-Za-z0-9_]*" n != null)
            (lib.attrNames e))
        withUpstream;

    # `needs` names COMMANDS for `command -v`, not packages and not paths. A path here would make
    # the preflight test something a consumer's extraPath can never satisfy.
    "every `upstream.needs` is a list of bare command names -- not packages, not paths" =
      lib.all
        (t:
          let n = t.upstream.needs or [ ]; in
          lib.isList n
          && lib.all (c: lib.isString c && builtins.match "[a-zA-Z0-9_.+-]+" c != null) n)
        withUpstream;

    # Measured on a real switch rather than predicted: codex's release-metadata parser is awk, for
    # both its CDN path and its GitHub fallback, so a host without it fails naming OpenAI's CDN.
    # Pinned to awk ALONE -- shasum/openssl/flock/wget are `command -v`-guarded with fallbacks, and
    # listing them would make a consumer install packages for code paths never taken.
    "codex declares awk and nothing else; no other entry declares a need" =
      cat.cli.openai-codex.upstream.needs == [ "awk" ]
      && lib.all (t: (t.upstream.needs or [ ]) == [ ])
        (lib.filter (t: t.upstream != null && t.binary != "codex") allEntries);

    # `installs` is joined onto $HOME by lib/install-upstream.sh. An absolute path or a `$HOME`
    # of its own would produce `/home/x//home/x/...` or an unexpanded literal, and the probe would
    # then never match -- which reads as "reinstalls on every activation", the exact regression
    # the idempotency gate exists to prevent.
    "every `upstream.installs` is RELATIVE to $HOME -- no leading slash, no embedded $HOME, no traversal" =
      lib.all
        (t:
          !(lib.hasPrefix "/" t.upstream.installs)
          && !(lib.hasPrefix "~" t.upstream.installs)
          && !(lib.hasInfix "$" t.upstream.installs)
          && !(lib.hasInfix ".." t.upstream.installs))
        withUpstream;

    # The probe path IS the command. If they diverge, the module verifies one file and puts a
    # different one on PATH -- and the divergence would only show up as "the tool installed fine
    # but the command is missing", on a host, after a switch.
    "every `upstream.installs` ends in the entry's own `binary` -- the idempotency probe and the command on PATH are the same file" =
      lib.all (t: builtins.baseNameOf t.upstream.installs == t.binary) withUpstream;

    # Not a style rule. modules/home.nix merges `cli` and `desktop` into one selection space, so a
    # key appearing in both groups would resolve to whichever group merged last, silently.
    "catalogue keys are unique across ALL groups -- the home-manager plane flattens them into one selection space" =
      lib.length allKeys == lib.length (lib.unique allKeys);

    # The entries that carry `upstream = null` each record what was checked (npm/Node-only
    # distribution or vendor Linux packages with no per-user installer script). Pinned so that
    # "add an installer URL" stays a deliberate edit with a
    # measurement behind it rather than something a refactor can invent.
    #
    # This list GREW on 2026-08-11 and the assertion is here to make that visible when it happens:
    # openai-codex moved out of the null set because the 403 it was recorded on came from a URL the
    # vendor never used. Updating this line is the moment to write down what was actually probed.
    "exactly the researched entries carry an upstream delivery path -- only the two desktop apps and gemini-cli carry recorded nulls" =
      sorted
        (lib.attrNames (lib.filterAttrs (_: t: t.upstream != null)
          (lib.foldl' (acc: g: acc // cat.${g}) { } (lib.attrNames cat))))
      == [ "claude-code" "deepseek-harness" "grok-build" "muse-code" "omp" "openai-codex" "opencode" "qwen-code" ];

    # codex was the first entry whose installer is steered by an environment variable
    # instead of a flag, and losing it turns a `home-manager switch` typed at a terminal into a
    # blocked activation waiting on "Start Codex now? [y/N]". Pinned at the value the vendor's own
    # updater uses, not at "some truthy string". muse-code is the second: without
    # MUSE_NO_MODIFY_PATH the installer appends a PATH export to a home-manager-generated rc.
    "codex carries the non-interactive env var its own installer gates every prompt on" =
      cat.cli.openai-codex.upstream.env == { CODEX_NON_INTERACTIVE = "1"; };

    "muse-code carries the no-modify-path env var its installer honours instead of a flag" =
      cat.cli.muse-code.upstream.env == { MUSE_NO_MODIFY_PATH = "1"; };

    # The measured fact behind `needsDynamicLoader = false`, pinned separately from the field-shape
    # assertion above: codex ships musl-static, so flagging it would demand nix-ld on hosts that
    # can run it bare. If a future release starts shipping a glibc build this must flip WITH it.
    # muse-code is the same shape: a statically linked binary, verified with `file`.
    "codex, grok and muse need no dynamic loader; DeepSeek's npx dispatcher uses the declared Nix runtime" =
      cat.cli.openai-codex.upstream.needsDynamicLoader == false
      && cat.cli.grok-build.upstream.needsDynamicLoader == false
      && cat.cli.muse-code.upstream.needsDynamicLoader == false
      && cat.cli.deepseek-harness.upstream.needsDynamicLoader == false
      && lib.all (n: cat.cli.${n}.upstream.needsDynamicLoader == true)
        [ "claude-code" "opencode" "omp" "qwen-code" ];
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
then pkgs.emptyFile
else
  throw ''
    nixagent: agents-eval check failed. Failing assertions:
    ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
  ''
