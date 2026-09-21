# SPDX-License-Identifier: MIT OR Apache-2.0
#
# The agent catalogue: clients for REMOTE frontier models -- one entry per selectable package,
# naming it on each platform this repo is willing to install from. Two shapes today, `cli` (a
# terminal binary) and `desktop` (a graphical application); THE PLACEMENT RULE below is why both belong
# in the same file despite the different interface.
#
# THE PLACEMENT RULE, stated as a boundary rather than a list, in the same shape nixsh's own
# lib/tools.nix header states its display rule:
#
#   Does the tool drive a remote frontier model it does not host, delivered as a package that
#   self-updates faster than nixpkgs tracks it?
#     yes -> it belongs here, catalogued as `cli` or `desktop` by whichever interface it actually
#            has -- that split is about grouping honestly, not about eligibility
#     no  -> it belongs to whichever repo owns the thing it actually is
#
# Whether the tool opens a terminal or a window is NOT the eligibility test. The category a person
# actually maintains is "my AI tooling", and a desktop client sits in it the same way a terminal
# one does: both carry the identical delivery problem below regardless of which surface renders
# the reply. A packaged `.desktop` entry separates `cli` from `desktop`; it does not separate "in
# this catalogue" from "not".
#
# Two neighbours this rule is drawn against, both of which could plausibly have claimed these
# entries, and neither of which should:
#
#   - nixllm SERVES models. Its domain is a broker, an inference engine, a model store, a GPU --
#     software that loads weights and answers requests. Everything catalogued below, `desktop`
#     included, is an HTTPS client that never loads a weight and has no opinion about a GPU. Same
#     project space, opposite side of the wire, so a shared catalogue would mean one repo whose
#     entries need two unrelated kinds of host to be useful.
#   - nixsh is universal BY CONSTRUCTION -- every host has a shell and reaches for a terminal tool,
#     which is exactly why that catalogue has no per-host story to build. These do not have that
#     property and must not inherit it: a small production server has a shell and wants `ripgrep`,
#     and emphatically does not want a self-updating agent client and its desktop runtime --
#     doubly true for `desktop`, which additionally needs a display the server does not have.
#     "Runs in a terminal" is a shape, not a domain; nixsh's claim is the domain "every host needs
#     this", and these fail it regardless of shape.
#
# ── THE RULE THIS REPO EXISTS FOR: NEVER nixpkgs, AND THE REASON IS NOT FRESHNESS ──────────────
#
# Every entry below carries `nixpkgs = null`. That null is a POLICY, not an absence, and the
# distinction matters enough to mechanise: checks/agents-eval.nix asserts it for every entry, so an
# addition that names a real nixpkgs attribute fails `nix flake check` rather than quietly opening
# the door this repo was drawn to keep shut.
#
# nixpkgs really does carry six of the eight CLIs. Force-evaluated -- not `hasAttrByPath` alone,
# which cannot tell a live attribute from a rename-to-throw. The original five were measured
# 2026-08-11 against nixpkgs-unstable HEAD d482ef84; the Grok and Qwen rows were measured
# 2026-09-04, the muse row the same day via pkgs/by-name (no muse-code entry; `muse` there is
# the unrelated MuSE audio sequencer, as on Arch). Each uses its project's release feed and the
# Arch package API alongside, because
# the ONLY honest version of this table is one with all three columns:
#
#                     nixpkgs-unstable   Arch/AUR            upstream
#     claude-code     2.1.226            2.1.222 (cachyos)   2.1.226
#     opencode        1.18.13            1.18.16 (extra)     1.18.16
#     codex           0.147.0            0.146.1 (extra)     0.147.0
#     gemini-cli      0.47.0             1:0.50.0 (extra)    0.54.4
#     omp             -- absent --       17.2.2 (AUR, flagged out of date)   17.2.12
#     grok-build      1.0.5              1.0.13 (AUR)        1.0.13
#     qwen-code       0.16.0             0.21.2 (extra)      0.23.0
#     deepseek-harness -- absent --       0.1.2rc.1 (AUR)     0.1.2-rc.1
#     muse-code       -- absent --       1.0.1.r2006.1 (AUR) 1.0.1-R2006.1
#
# READ THAT TABLE HONESTLY: nixpkgs is not uniformly behind. It is AHEAD of Arch for codex and for
# claude-code, level for opencode's packaging lag, and catastrophically behind only for gemini-cli
# -- which nixpkgs is winding down rather than tracking (see that entry). An earlier revision of
# this header claimed "every one of the four is behind the distro package". That was true of the
# snapshot it was taken from (2026-08-03) and is false now. Freshness is a race that changes hands
# week to week, so a rule resting on it would have to be re-argued every week.
#
# THE RULE DOES NOT REST ON IT. It rests on ONE structural property, and this is the whole reason:
#
#     THESE TOOLS SELF-UPDATE, AND A STORE PATH IS READ-ONLY.
#
# Each of them ships its own updater and expects to rewrite its own install on a cadence measured
# in days. `/nix/store` is immutable by construction, so the updater cannot run AT ALL -- not
# slowly, not with a warning: the version freezes until a human bumps a flake.lock, and the tool
# spends the interval telling its operator to update while being structurally unable to. That
# argument does not depend on how fresh nixpkgs is, and a nixpkgs that was perfectly current would
# still fail it. Freshness is the symptom; immutability is the cause.
#
# So there is no `nixpkgs` field to fill in and no `nixosModules` output -- see ../README.md.
#
# ⚠ AND THE BOUNDARY THAT FOLLOWS, because "never nixpkgs" has been over-read as "never nix":
# the prohibition is on nix owning the TOOL. It says nothing about nix supplying the tool's
# RUNTIME or the installer's own dependencies. `programs.nix-ld` providing a loader, and
# `nixagent.home.extraPath` handing the installer a nixpkgs curl and bash, are not exceptions to
# the rule -- they are the rule working. Nix builds the ground the vendor's artifact stands on;
# the artifact stays the vendor's.
#
# ── TWO DELIVERY MODES, BECAUSE THE AUR IS NOT ALWAYS FRESH EITHER ─────────────────────────────
#
# The reasoning above is about nixpkgs, and it holds. What it does NOT establish is that a distro
# package is always current -- and for a fast-moving entry it measurably is not. The `omp` and
# `gemini-cli` rows above are the measurement: an `omp-updater` bot is listed as a co-maintainer on
# both AUR packages and they are ten patch releases behind anyway. That is the same failure mode as
# a stale nixpkgs derivation wearing a different hat. A packager is a human in the loop of a
# project that ships several times a week.
#
# So a SECOND delivery plane exists alongside the distro one: use the VENDOR's own mutable
# per-user delivery mechanism, which is what these projects actually support and test. Usually
# that is the vendor's installer and leaves `<tool> update` working afterwards. DeepSeek Harness
# is the one different case: its official invocation is `npx @deepseek-ai/dsh`, so the plane writes
# an unversioned `dsh` dispatcher around that command and lets npm's cache own the payload. The two
# planes are chosen PER HOST by the
# consumer -- pacman/AUR on an Arch box that already reconciles packages, upstream on a NixOS box
# that has no such reconciler and would otherwise get nothing at all. Neither is forced, and this
# file makes no attempt to rank them: which one is right is a fact about the host.
#
# ── WHAT A HOST WITH NEITHER IS SUPPOSED TO DO ─────────────────────────────────────────────────
#
# A NixOS host has no pacman, so the upstream plane is its ONLY plane here, and an entry whose
# vendor ships no installer is simply absent on it. That is a real limit and it is recorded rather
# than papered over -- `upstream = null` is a finding with a date and a method attached, and
# ../modules/home.nix derives its option type from the entries that have one, so selecting such a
# tool is an eval error instead of an activation that quietly fetches nothing.
#
# It is a limit, NOT a licence to reach for nixpkgs: the structural argument above applies hardest
# to exactly these entries. The catalogued way out is a vendor installer appearing, which is not
# hypothetical -- `openai-codex` sat at `upstream = null` for four days on a measured 403 and now
# carries a live record, because the URL that answered 403 was never the vendor's (see that entry).
# Re-probe before concluding a tool is unreachable; a 403 is a fact about a URL, not about a tool.
#
# The other candidate way out has been considered and is still NOT accepted as an upstream mode:
# `npm install -g` installs into whichever node prefix the host happens to have configured, which
# makes `installs` a property of the host rather than of the tool. DeepSeek's `npx` method does not
# pretend otherwise: no global npm prefix is invented and no package is pinned or copied into one;
# a small dispatcher runs the exact vendor-documented command and npm owns its own cache.
#
# Mechanically the two modes live on different planes: `arch`/`aur`/`archRepoOn`/`archPackageOn` feed
# ../modules/nixagent.nix (system-manager, publishes package-name lists), `upstream` feeds
# ../modules/home.nix (home-manager, runs the installer once per user). NOTHING about the upstream
# mode pins a version -- see ../lib/install-upstream.sh's header for the contract in full.
#
# ── FIELDS ─────────────────────────────────────────────────────────────────────────────────────
#
# `arch`        the plain-Arch package name: official repository when `aur = false`, AUR when true.
# `binary`      the command it actually installs. NOT always the package name -- `openai-codex`
#               ships `codex`, `claude-code` ships `claude`. Published as `nixagent.binaries` for
#               a consumer writing config or a launcher against these tools, because pointing
#               either at the PACKAGE name is a command that does not exist. Same reasoning as
#               nixmsg's own `binary` field, which exists because "telegram-desktop" launches
#               nothing.
# `aur`         (default false) the name lives in the AUR rather than an official Arch repo. Load-
#               bearing in one direction only, and fatally: `pacman -S` resolves a transaction
#               atomically, so ONE AUR name in a pacman list fails the whole thing with "target not
#               found" and takes every unrelated package in the same converge down with it.
# `archRepoOn`  (default [ ]) Arch DERIVATIVES whose own repositories carry an otherwise-AUR name,
#               so a host on one of them gets the repo build instead of a source build. Consumed
#               against `nixagent.distro` -- see ../modules/nixagent.nix. Present only on entries
#               that need it.
# `archPackageOn`
#               (default { }) package-name overrides keyed by derivative. Only for the real case
#               where the derivative repository publishes the same application under a different
#               name from the AUR floor. Its keys must also appear in `archRepoOn`: an override is
#               emitted only when that derivative's repository is the selected source.
# `nixpkgs`     always null. See above. The field is present rather than omitted so that a reader
#               cannot mistake the policy for an oversight.
# `upstream`    the vendor's own per-user delivery method, or null. Present on EVERY entry for the same
#               reason `nixpkgs` is -- checks/agents-eval.nix asserts the field exists, so "this
#               tool has no vendor delivery path" is a recorded finding rather than a blank.
#               Every non-null entry has `kind = "installer"` or `kind = "npx"` plus `installs`,
#               the relative command path. Installer entries additionally carry:
#
#                 url       the installer, fetched over HTTPS.
#                 runner    the interpreter to run it with. Not always bash: omp's is `#!/bin/sh`
#                           and POSIX throughout, claude's and opencode's are bash and use bash
#                           features. Recorded per entry rather than assumed, because running a
#                           bash installer under dash fails in ways that look like network faults.
#                 args      flags needed to make the install DETERMINISTIC. Not cosmetic -- see
#                           the omp and opencode entries, where the default invocation either
#                           installs somewhere else entirely or edits the user's shell rc files.
#                 env       (default { }) environment variables exported FOR THE INSTALLER RUN
#                           ONLY, for a vendor whose non-interactive switch is an env var rather
#                           than a flag. Same job as `args` and the same standard of evidence:
#                           nothing goes in here that the vendor does not itself document or use.
#                           Exists for `openai-codex`, whose installer has exactly two flags
#                           (`--release`, `--help`) and gates every prompt on `CODEX_NON_INTERACTIVE`
#                           -- and whose OWN self-updater sets that variable when re-running it.
#                 needs     (default [ ]) commands the installer requires BEYOND the universal
#                           floor (curl, the runner, env), preflighted by name before anything is
#                           fetched. Not a dependency list for a package manager -- this repo
#                           installs nothing -- but the names a consumer's `nixagent.home.extraPath`
#                           has to satisfy on a host with no FHS.
#
#                           IT EXISTS BECAUSE THE FAILURE WITHOUT IT LIES. codex parses release
#                           metadata with a hand-written JSON tokeniser in awk, for both its CDN
#                           path and its GitHub fallback. With no awk on an activation's PATH both
#                           fail in turn and the install dies reporting "Could not parse
#                           releases.openai.com release metadata for Codex latest", plus a broken
#                           pipe from the `fold` feeding it. That names OpenAI's CDN for what is a
#                           missing coreutils-adjacent binary, and sends a reader to the network.
#                           Exactly the class of misdirection the curl and runner preflights above
#                           already exist to prevent; this generalises them per entry.
#
#                           ONLY HARD REQUIREMENTS BELONG HERE. A tool the installer guards with
#                           `command -v` and has a fallback for is NOT a need -- codex probes
#                           shasum/openssl/flock/wget that way and works without every one of them.
#                           Listing those would make a host install packages to satisfy a preflight
#                           for code paths it never takes.
#                 installs  the launcher the installer creates, RELATIVE TO $HOME. This is the
#                           idempotency probe (present -> nothing is fetched), the post-install
#                           verification target, and the directory added to PATH. Its basename is
#                           always the entry's `binary`; checks/agents-eval.nix asserts that.
#                 needsDynamicLoader
#                           whether the artifact that lands requires the FHS dynamic loader at
#                           `/lib64/ld-linux-x86-64.so.2`. That is a HOST REQUIREMENT a
#                           distro-agnostic catalogue cannot assume: NixOS has no FHS and provides
#                           the path only via `programs.nix-ld`, configured rather than merely
#                           enabled. When true, lib/install-upstream.sh preflights the loader and
#                           aborts before downloading, instead of letting the binary fail at exec
#                           with an ENOENT naming a file that is plainly present.
#
#                           A FIELD AND NOT AN UNCONDITIONAL CHECK, because "no loader" is fatal
#                           only to an artifact that wants one. An installer that dropped a shell
#                           script would work perfectly on a host that fails this test, and
#                           refusing it there would be a false negative rather than caution.
#
#                           ⚠ IT IS NOT "IS THIS A NATIVE BINARY", which is what this field was
#                           called until 2026-08-11 and is the reason it is not called that now.
#                           `openai-codex` ships the most native artifact in the catalogue -- a
#                           258 MB Rust executable -- and needs NO loader, because it is a
#                           static-PIE musl build with no PT_INTERP segment at all (verified by
#                           parsing the program headers of the release asset: 9 phdrs, 4x LOAD +
#                           DYNAMIC/TLS/GNU_EH_FRAME/GNU_STACK/GNU_RELRO, no INTERP). Naming the
#                           field after the artifact rather than after the requirement would have
#                           made codex demand nix-ld on hosts that can run it bare -- a false
#                           prerequisite, which is precisely the false negative the paragraph above
#                           says this field exists to avoid.
#
#               An `npx` entry instead carries `package`, the official unversioned npm package
#               spec. modules/home.nix creates a dispatcher at `installs` that runs
#               `npx --yes <package> "$@"`; the harness stays outside the store and npm owns its
#               cache. Its runtime names Node and pnpm explicitly, so the dispatcher is usable in
#               the interactive home as well as during its first activation-time smoke test.
#
#               The prefix belongs to the INSTALLER, not to this catalogue: `installs` records
#               where each vendor puts things, it does not decide it. They do not agree with each
#               other (opencode uses ~/.opencode/bin, the other two ~/.local/bin), which is why
#               this is a per-entry field and not one module-wide `prefix` option pretending to
#               steer something it cannot.
# `note`        why the entry is what it is, where that is not obvious from the name.
#
# ── THE ATTRIBUTE KEY NAMES THE TOOL, NOT THE PACKAGE ──────────────────────────────────────────
#
# Most keys below happen to equal their `arch` value, which can make the
# key look like "the pacman name". It is not, and `omp` is where that stops being a coincidence:
# its pacman name is `oh-my-pi-bin`, where `-bin` is an AUR packaging convention distinguishing
# one of TWO AUR packages for the same tool, and the key is also what a consumer writes on the
# home-manager plane, where the AUR does not exist and `-bin` would be meaningless. So the key is
# the name the project uses for itself; `arch` and `binary` and `upstream` are what each delivery
# mode calls it. Keys are unique across ALL groups (checks/agents-eval.nix asserts it), because
# ../modules/home.nix flattens the groups into one selection space.
#
# ── VERIFIED, NOT GUESSED ──────────────────────────────────────────────────────────────────────
#
# Every `arch` name below was checked against THREE independent sources, because two
# of them disagree for one entry and only the third resolves it:
#
#   - `pacman -Si <name>` on a live CachyOS system, which reports the repository a name resolves in.
#   - archlinux.org's own package search API (`/packages/search/json/?name=<name>`), which is
#     upstream Arch and knows nothing about a derivative's extra repositories.
#   - the AUR RPC (`https://aur.archlinux.org/rpc/v5/info?arg[]=<name>`).
#
# A `pacman -Si` hit alone is NOT sufficient evidence for `aur = false`, and this catalogue is the
# proof: `claude-code` resolves cleanly in `pacman -Si` on a CachyOS box and is in no upstream Arch
# repository at all. Trusting the first source alone would have written `aur = false` and handed
# every plain-Arch consumer the whole-transaction abort described above.
#
# ── CONSIDERED AND EXCLUDED ────────────────────────────────────────────────────────────────────
#
# Named here rather than silently left out, so the boundary is decidable for the next candidate
# instead of re-argued:
#
#   - local inference runners of every kind (an engine, a model-serving GUI, a weights converter).
#     Those load weights, which is nixllm's domain by the boundary above, not a matter of taste.
{ ... }:
{
  # ── Agentic CLIs: an interactive terminal agent driving a remote frontier model ──────────────
  cli = {
    claude-code = {
      arch = "claude-code";
      binary = "claude";
      nixpkgs = null;

      # THE ONE ENTRY THAT IS NOT THE SAME ANSWER ON EVERY ARCH-FAMILY HOST, and the reason
      # `archRepoOn` exists at all. Checked three ways on 2026-08-07:
      #
      #   archlinux.org package search  -> 0 results. Upstream Arch does not package it, in any
      #                                    repository, on any architecture.
      #   AUR RPC                       -> present, PackageBase `claude-code`, maintained, ~87
      #                                    votes. This is where a plain Arch host gets it.
      #   `pacman -Si claude-code`      -> found, `Repository: cachyos`. Note the repository name:
      #                                    CachyOS's OWN repo, not one of its `*-v3` rebuilds of an
      #                                    Arch repo, so this is a package that exists because that
      #                                    derivative chose to ship it.
      #
      # Hence `aur = true` as the FLOOR -- correct for upstream Arch, and the direction that cannot
      # abort a transaction -- with `archRepoOn` lifting it to the pacman list only on a distro
      # whose own repository is known to carry it. A host that declares nothing gets the safe
      # answer; see `nixagent.distro` in ../modules/nixagent.nix.
      aur = true;
      archRepoOn = [ "cachyos" ];

      # Anthropic's own installer, and the entry the upstream mode was built against because it was
      # already in use by hand on a host here: `~/.local/bin/claude` pointing into
      # `~/.local/share/claude/versions/<version>`, which is this installer's layout.
      #
      # `installs` is NOT readable out of install.sh, and that is worth stating rather than
      # implying. The script (read 2026-08-10) only downloads a versioned binary into
      # `~/.claude/downloads`, checksums it against the release manifest, runs `<binary> install`,
      # and deletes the download. The launcher path is decided inside that `install` subcommand,
      # so the value below is taken from a live host where this installer was used, not from the
      # script -- and the post-install verification in ../lib/install-upstream.sh is what turns a
      # wrong guess into a loud failure instead of a silent one.
      #
      # No args: the script takes an optional `stable|latest|VERSION` target and defaults to
      # latest, which is exactly what is wanted -- pinning a version here would reintroduce the
      # problem this repo exists to avoid. It also refuses to run under sudo (it would install
      # into root's home), which suits a home-manager activation exactly.
      upstream = {
        kind = "installer";
        url = "https://claude.ai/install.sh";
        runner = "bash";
        args = [ ];
        installs = ".local/bin/claude";
        # linux-x64 artifact: `Elf file type is EXEC`, `INTERP /lib64/ld-linux-x86-64.so.2`.
        # Its musl fallback is unreachable on NixOS -- the detection is
        # `[ -f /lib/libc.musl-*.so.1 ] || ldd /bin/ls | grep -q musl`, and NixOS has no /bin/ls,
        # so it selects the glibc build on exactly the hosts that cannot run it unaided.
        needsDynamicLoader = true;
      };

      note = ''
        Anthropic's agentic coding CLI (github.com/anthropics/claude-code). Package `claude-code`,
        command `claude`.
      '';
    };

    deepseek-harness = {
      # DeepSeek's own harness, not one of the similarly named community CLIs. Verified
      # 2026-09-04 against the same three package sources as every distro-plane entry:
      #
      #   archlinux.org package search  -> no DeepSeek harness package in an official repository.
      #   AUR RPC                       -> deepseek-harness-bin 0.1.2rc.1-1, current with npm.
      #   AUR PKGBUILD                  -> the official @deepseek-ai/dsh tarball, installed as dsh.
      #
      # The `-bin` package is the right floor: it consumes the published npm artifact rather than
      # cloning and rebuilding DeepSeek's large pnpm workspace on each workstation.
      arch = "deepseek-harness-bin";
      binary = "dsh";
      nixpkgs = null;
      aur = true;

      # DeepSeek documents `npx @deepseek-ai/dsh web` as the supported npm launch, not a shell
      # installer and not a global npm prefix. The upstream plane therefore writes an unversioned
      # dispatcher at ~/.local/bin/dsh around that exact package invocation. npm owns the fetched
      # payload and cache; Nix owns only Node/pnpm runtime ground. `--yes` suppresses npx's first-
      # download prompt, which cannot be answered from a home-manager activation or menu launch.
      upstream = {
        kind = "npx";
        package = "@deepseek-ai/dsh";
        installs = ".local/bin/dsh";
        needsDynamicLoader = false;
      };

      # Node 24.19.0 satisfies the repository's `^22.19.0 || >=24.0.0` engine declaration. pnpm
      # is a real runtime dependency rather than build debris: `dsh plugin` forwards plugin
      # operations to it. The AUR package declares both itself, so only the NixOS plane needs the
      # explicit package names here.
      runtime = {
        archPackages = [ ];
        nixpkgsPackages = [ "nodejs" "pnpm" ];
      };

      note = ''
        DeepSeek AI's first-party developer-preview agent harness
        (github.com/deepseek-ai/deepseek-harness). Catalogue key `deepseek-harness`, AUR package
        `deepseek-harness-bin`, command `dsh`, official npm package `@deepseek-ai/dsh`.

        The project explicitly warns that it is experimental, unaudited and compatibility-
        breaking. Its default supported surface is a local Web UI (`dsh web`); it can execute
        model-generated commands and load plugins, so the launcher does not invent an unrestricted
        flag beyond the project's own defaults.
      '';
    };

    gemini-cli = {
      arch = "gemini-cli";
      binary = "gemini";
      nixpkgs = null;

      # NO VENDOR INSTALLER, and RE-PROBED 2026-08-11 rather than left on the earlier note --
      # because the sibling entry below shows what a stale probe costs. Every candidate answers 404
      # (raw .../main/install.sh, .../master/install.sh, .../main/scripts/install.sh), gemini-cli.dev
      # does not resolve, and storage.googleapis.com/gemini-cli/install.sh answers 403. The README
      # documents npx, `npm install -g`, Homebrew, MacPorts and conda -- no shell installer.
      #
      # AND NO BINARY TO PLACE EITHER, which the earlier note got wrong by inference. The last 15
      # releases (stable, preview and nightly alike) carry an IDENTICAL three-asset set:
      # gemini-cli-bundle.zip plus two darwin zips. There is no Linux artifact at all, and the
      # bundle is not one -- `gemini.js` opens `#!/usr/bin/env node`. The project's own
      # scripts/build_binary.js has a working linux branch; Google simply does not publish its
      # output. So this is npm/Node-only on Linux, not "binaries with no script to place them".
      #
      # `npm install -g` is deliberately NOT accepted as an upstream mode here. It installs into
      # whichever node prefix happens to be configured -- a nix-store node's prefix is read-only,
      # a system node's is root-owned -- so the destination this catalogue would have to record as
      # `installs` is a property of the host's node setup rather than of the tool. That is exactly
      # the ambiguity the probe path exists to remove. It is not unfixable, and the header says
      # where the fix would have to live (a module option for the prefix, a field for the package
      # name); it is not built because nothing has asked for it and this entry may not be the one
      # to ask -- see the retirement note below.
      upstream = null;

      note = ''
        Google's terminal agent for Gemini (github.com/google-gemini/gemini-cli). Package
        `gemini-cli`, command `gemini`. Official upstream Arch `extra` (archlinux.org search:
        `extra`, x86_64, 2026-08-07), so no AUR helper is needed for it anywhere.

        Distro-plane only: with no vendor installer, a host that cannot use pacman gets nothing
        for this entry, and says so at eval time rather than at runtime -- `nixagent.home.upstream`
        is typed to the entries that HAVE an installer, so naming this one there is a type error.

        ⚠ THE VENDOR IS RETIRING IT, which is context this catalogue should carry before anyone
        spends effort widening a plane to reach it. Google announced Gemini CLI's replacement by
        Antigravity CLI, and nixpkgs marked the package accordingly on 2026-08-07:
        `meta.problems.removal.message` reads "Unpaid tier and Google AI Pro/Ultra users: Gemini
        CLI was replaced by Antigravity CLI." That also explains the freshest measurement in this
        file's header -- nixpkgs has not bumped this package since 2026-06-22 and is 8 stable
        releases behind, which is a wind-down rather than a packaging lag. `antigravity-cli` is
        already in nixpkgs (1.1.11, a fetched-binary package). Whether this catalogue follows the
        vendor there is a decision for a consumer, not something to infer here.
      '';
    };

    grok-build = {
      # The PRODUCT is Grok Build, the package is `grok-build`, and the command is `grok`.
      # Verified 2026-09-04 against all three package sources used for this catalogue:
      #
      #   archlinux.org package search  -> 0 results for grok, grok-build and grok-cli.
      #   AUR RPC                       -> grok-build 1.0.13-1, matching x.ai/cli/stable.
      #   `pacman -Si` on CachyOS       -> no repository package under any of those names.
      #
      # The AUR package downloads the same versioned binary as the vendor installer and places it
      # at /usr/bin/grok. It is therefore the correct distro-plane floor on both Arch variants.
      arch = "grok-build";
      binary = "grok";
      nixpkgs = null;
      aur = true;

      # SpaceXAI's documented installer. Its default layout is ~/.grok/downloads for versioned
      # artifacts with ~/.grok/bin/grok pointing at the active one; `grok update` uses the same
      # channel-aware layout afterwards. The installer normally offers to append ~/.grok/bin to a
      # shell rc, but modules/home.nix prepends the catalogue-derived install prefix to PATH before
      # invoking it, so its own `path_has_dir` gate leaves generated shell files alone.
      upstream = {
        kind = "installer";
        url = "https://x.ai/cli/install.sh";
        runner = "bash";
        args = [ ];
        installs = ".grok/bin/grok";

        # Official stable 1.0.13 linux-x86_64 artifact, inspected 2026-09-04: ELF PIE with no
        # PT_INTERP (`file`: "static-pie linked"). It starts on NixOS without the FHS loader.
        needsDynamicLoader = false;
      };

      note = ''
        SpaceXAI's terminal coding agent and TUI (github.com/xai-org/grok-build). Catalogue and
        package key `grok-build`; command `grok`. It supports interactive, headless and ACP modes,
        plus AGENTS.md, skills, plugins, hooks, MCP servers and subagents.
      '';
    };

    muse-code = {
      # Meta's terminal coding agent, powered by Muse Spark. Verified 2026-09-04 against the
      # same three package sources as every distro-plane entry:
      #
      #   archlinux.org package search  -> 0 results for muse-code. (`muse` in extra is the
      #                                    unrelated MuSE audio sequencer, 4.2.1.)
      #   AUR RPC                       -> muse-code-bin 1.0.1.r2006.1-1, current with upstream
      #                                    1.0.1-R2006.1 (checked via the release asset's own
      #                                    `--version`). Provides muse-code/musecode/muse-bin/
      #                                    musecode-bin; conflicts with the bare names.
      #   `pacman -Si` on CachyOS       -> neither muse-code nor muse-code-bin in any configured
      #                                    repository, so no derivative lift applies.
      #
      # The `-bin` package is the right floor: it consumes Meta's published release binary from
      # lookaside.facebook.com rather than rebuilding anything.
      arch = "muse-code-bin";
      binary = "muse";
      nixpkgs = null;
      aur = true;

      # Meta's documented installer. Default layout is ~/.local/bin/muse (overridable via
      # MUSE_INSTALL_DIR); the script downloads the launcher to a file first, checks it with
      # `bash -n` plus the advertised sha256, then runs it with MUSE_LAUNCHER_INSTALL=1 --
      # never `curl | sh`, which is also why this plane can trust it. `installs` records the
      # launcher path, which is the idempotency probe and the PATH entry alike.
      #
      # MUSE_NO_MODIFY_PATH arrives via `env`, not `args`: the installer honours no flag for
      # this, and without it the script appends a PATH export to a home-manager-generated shell
      # rc -- the same reason opencode takes `--no-modify-path` and qwen takes its own.
      upstream = {
        kind = "installer";
        url = "https://dev.meta.ai/install.sh";
        runner = "bash";
        args = [ ];
        env = { MUSE_NO_MODIFY_PATH = "1"; };
        installs = ".local/bin/muse";

        # Release asset muse-x86-linux 1.0.1-R2006.1, inspected 2026-09-04: ELF 64-bit LSB
        # executable, statically linked. It starts on NixOS without the FHS loader, like codex
        # and grok-build -- flagging it would demand nix-ld on hosts that run it bare.
        needsDynamicLoader = false;
      };

      note = ''
        Meta's terminal coding agent (dev.meta.ai), powered by Muse Spark. Catalogue key
        `muse-code`; AUR package `muse-code-bin`; command `muse` (not muse-code -- the top
        cause of a false command-not-found). Interactive TUI plus `exec` headless mode,
        parallel subagents, skills, MCP servers, and an OS sandbox that stays on unless
        `--yolo` is passed.
      '';
    };

    openai-codex = {
      arch = "openai-codex";
      binary = "codex";
      nixpkgs = null;

      # Codex's Linux sandbox uses the first `bwrap` executable on PATH. If none exists it falls
      # back to a bundled helper, but that helper depends on unprivileged user namespaces and the
      # client emits a startup warning. OpenAI's sandbox prerequisites explicitly recommend the
      # distribution package for a reliable setup:
      # https://developers.openai.com/codex/concepts/sandboxing#prerequisites
      #
      # This is runtime ground, not the agent binary: pacman owns it on the distro plane and
      # nixpkgs owns it on the home-manager plane, while Codex itself remains vendor-owned and
      # self-updatable. Keep both names in the catalogue so the requirement follows the selection
      # rather than being copied into every host that happens to select Codex today.
      runtime = {
        archPackages = [ "bubblewrap" ];
        nixpkgsPackages = [ "bubblewrap" ];
      };

      # ⚠ THIS ENTRY READ `upstream = null` FROM 2026-08-07 TO 2026-08-11, AND THAT WAS WRONG.
      # The recorded finding was "openai.com/codex/install.sh answers 403". The URL answers 403
      # because it was never OpenAI's -- the installer is served from a different host entirely,
      # and the project README has documented it the whole time:
      #
      #     curl -fsSL https://chatgpt.com/codex/install.sh | sh        -> HTTP 200, 30285 bytes
      #
      # A 403 is a fact about a URL, not about a tool, and treating one as the other kept this tool
      # off every NixOS host for four days. The lesson is in the header: re-probe before concluding
      # a vendor ships nothing, and probe what the vendor DOCUMENTS rather than what a naming
      # convention suggests.
      #
      # `sh`, not bash: the script opens `#!/bin/sh` and is POSIX throughout.
      #
      # NO `args`, because there are only two (`--release VERSION`, `--help`) and neither is
      # wanted -- pinning a release here would reintroduce exactly what this plane avoids. The two
      # non-default behaviours this install DOES need steering are handled the only ways the vendor
      # offers, and both are load-bearing:
      #
      #   1. `env.CODEX_NON_INTERACTIVE = "1"`. The installer ends in `maybe_launch_codex_now`,
      #      which calls `prompt_yes_no "Start Codex now?"`. That helper returns early only for
      #      this variable; otherwise it tests `( : </dev/tty )` FIRST, before `[ -t 0 ]`. An
      #      activation run from a systemd unit has no tty and would fall through harmlessly -- but
      #      a `home-manager switch` typed at a terminal HAS one, so the switch would stop at an
      #      interactive prompt and, if answered, launch a TUI from inside an activation script.
      #      Not a guess at a magic variable either: codex's own updater re-runs this installer as
      #      `curl -fsSL <url> | CODEX_NON_INTERACTIVE=1 sh` (codex-rs/tui/src/update_action.rs).
      #   2. The PATH prepend in ../lib/install-upstream.sh. This installer has NO
      #      `--no-modify-path` equivalent: its `add_to_path` returns early ONLY when `$BIN_DIR` is
      #      already in `$PATH`, and otherwise writes a `# >>> Codex installer >>>` block into a
      #      shell rc chosen by `pick_profile` (~/.bashrc, ~/.zshrc, or ~/.profile for any other
      #      shell -- fish lands in the last). An activation inherits no login PATH, so without the
      #      prepend this installer edits a file nix believes it owns, on every fresh install.
      upstream = {
        kind = "installer";
        url = "https://chatgpt.com/codex/install.sh";
        runner = "sh";
        args = [ ];
        env = { CODEX_NON_INTERACTIVE = "1"; };

        # Measured on the first real switch that selected this entry (2026-08-11), not predicted:
        # the install failed with "Could not parse releases.openai.com release metadata for Codex
        # latest" on a host whose PATH had curl, bash, coreutils, tar, gzip, unzip, grep and sed --
        # everything the other three installers need, and no awk. `parse_release_metadata` is
        # `LC_ALL=C fold -b -w 4096 | LC_ALL=C awk '<a JSON tokeniser>'`, and the GitHub fallback
        # parses the same way, so both sources "fail" identically and the diagnostic names the CDN.
        #
        # awk ONLY. sha256sum comes from coreutils and is codex's first choice; shasum, openssl,
        # flock, lockf and wget are all `command -v`-guarded with working fallbacks.
        needs = [ "awk" ];

        installs = ".local/bin/codex";

        # FALSE, and it is the entry that made the field's name a bug worth fixing -- see the
        # `needsDynamicLoader` documentation in the FIELDS section above. Every Linux artifact in
        # the release is `-unknown-linux-musl`; there is no `-linux-gnu` build of the CLI at all.
        # Program headers parsed off the actual asset: ET_DYN, 9 phdrs, 4x LOAD + DYNAMIC + TLS +
        # GNU_EH_FRAME + GNU_STACK + GNU_RELRO. No INTERP segment, so it is a static PIE and starts
        # on a host with no FHS and no nix-ld whatsoever.
        needsDynamicLoader = false;
      };

      note = ''
        OpenAI's terminal coding agent (github.com/openai/codex). Official upstream Arch `extra`
        (verified 2026-08-07).

        THE PACKAGE AND THE COMMAND DISAGREE, in both directions from the upstream project name:
        the pacman package is `openai-codex` (the bare `codex` is taken on Arch), the command it
        installs is `codex`, and the project repository is `openai/codex`. A caller that guesses
        either name from the other is wrong half the time -- which is what `binary` is for.

        The installer places versioned release directories under `~/.codex/packages/standalone` and
        points `~/.local/bin/codex` at the current one, so `codex update` keeps working afterwards
        -- which is the post-condition this whole plane exists for. Where a store path WOULD have
        broken it is worth recording precisely, because codex fails softly rather than loudly:
        `install-context` classifies an unrecognised exe path as `InstallMethod::Other`, which maps
        to no update action, so the TUI silently stops offering updates and `codex update` exits
        with "Could not detect the Codex installation method". Frozen, with no error to search for.

        On Linux, selecting this entry also installs the distribution's `bubblewrap` package.
        Codex uses the first `bwrap` on PATH; its bundled helper is a fallback rather than the
        declared host prerequisite.
      '';
    };

    opencode = {
      arch = "opencode";
      binary = "opencode";
      nixpkgs = null;

      # The one catalogued installer that does NOT use ~/.local/bin, and the reason `installs` is
      # a per-entry field instead of one module-wide prefix option. Read out of the script itself
      # (2026-08-10, line 68): `INSTALL_DIR=$HOME/.opencode/bin`, hard-coded, honouring no env
      # var, followed by `mv`/`chmod 755` of the downloaded binary into it.
      #
      # `--no-modify-path` IS REQUIRED, not tidiness. Without it the installer walks
      # `$HOME/.bashrc $HOME/.bash_profile $XDG_CONFIG_HOME/bash/*` (or the zsh/fish equivalents),
      # picks the first that exists, and appends a PATH export to it. On a home-manager-managed
      # home those files are generated, so the edit is either lost on the next switch or fights
      # it -- and the PATH entry is this module's job anyway (`nixagent.home.addToPath` publishes
      # it through home.sessionPath, declaratively, where it survives).
      upstream = {
        kind = "installer";
        url = "https://opencode.ai/install";
        runner = "bash";
        args = [ "--no-modify-path" ];
        installs = ".opencode/bin/opencode";
        # A glibc binary, and the one whose installer verifies NOTHING after unpacking -- no smoke
        # test at all -- so a host without a loader gets a broken executable and no complaint from
        # the vendor script. The loader preflight is what turns that into a legible failure.
        needsDynamicLoader = true;
      };

      note = ''
        Open-source terminal coding agent (github.com/anomalyco/opencode), model-agnostic: it
        talks to whichever provider it is configured for rather than one vendor's endpoint. Still
        a client by the placement rule -- being able to point it at a locally-served model does not
        make it an inference engine, exactly as a browser is not a web server.

        Official upstream Arch `extra` (verified 2026-08-07). Package name, command name and
        project name all agree, which is worth noting only because several entries here do not.
      '';
    };

    omp = {
      # THREE NAMES FOR ONE TOOL, all different, which makes this the sharpest example of the
      # trap `binary` exists for -- worse than `openai-codex`, which only has two:
      #
      #   catalogue key   `omp`                          what the project calls itself
      #   pacman          `oh-my-pi-bin`                 the AUR package
      #   npm             `@oh-my-pi/pi-coding-agent`    what the source install pulls
      #   command         `omp`
      #
      # The npm name is recorded here rather than in a field because nothing in this repo installs
      # from npm -- it is the payload of the vendor installer's OWN source branch, and it is
      # written down because a reader searching for "oh-my-pi" in a lockfile or a bun global
      # directory will find that string and nothing else.
      arch = "oh-my-pi-bin";
      binary = "omp";

      # `nixpkgs = null` here is the policy as everywhere, but note that it is also the FACT for
      # once. Force-evaluated against the pinned revision on 2026-08-10: no `omp`, no `oh-my-pi`.
      # There IS a `pkgs.pi-coding-agent` and it is a trap -- version 0.83.0, homepage pi.dev,
      # mainProgram `pi`. That is Mario Zechner's pi-mono, the project omp FORKED FROM, not omp.
      # A reader pattern-matching on the npm name `@oh-my-pi/pi-coding-agent` would install a
      # different agent under a different command and think the catalogue was being precious.
      nixpkgs = null;

      # AUR-ONLY, AND THE FIRST ENTRY WHERE THE AUR IS ITSELF THE STALE COPY. All three names
      # checked 2026-08-10 against the same three sources this file's header requires:
      #
      #   archlinux.org package search  -> 0 results for `oh-my-pi-bin`, `oh-my-pi` AND `omp`.
      #                                    Upstream Arch packages none of them.
      #   AUR RPC                       -> both present, both flagged out of date (below).
      #   `pacman -Si`                  -> not found on a CachyOS host for any of the three, so
      #                                    unlike `claude-code` there is no derivative repository
      #                                    to lift it to the pacman list. `aur = true` is the
      #                                    whole answer and there is no `archRepoOn`.
      aur = true;

      # WHICH OF THE TWO AUR PACKAGES: `oh-my-pi-bin`, the prebuilt release binary. They conflict
      # with each other (`oh-my-pi-bin` declares Provides+Conflicts on `oh-my-pi`), so this is a
      # real choice, and the source package loses it on build cost rather than on principle. AUR
      # RPC, 2026-08-10:
      #
      #   oh-my-pi-bin  17.2.2-1  depends: glibc
      #                           makedepends: none      6 votes,  popularity 2.63
      #                           flagged out-of-date 2026-08-08
      #   oh-my-pi      17.2.3-1  depends: glibc opus pcre2
      #                           makedepends: bazel bun git   2 votes, popularity 0.84
      #                           flagged out-of-date 2026-08-04
      #
      # `oh-my-pi` builds the project's ~55k-line Rust engine plus its Bun/TypeScript frontend
      # from source, under bazel, on every version bump -- of a project that ships several
      # releases a week, on hosts whose package converge is meant to be unattended. That is a
      # long build repeated constantly for a binary upstream already publishes. It is also the
      # heavier dependency set for the same result.
      #
      # Note what the two versions say together, because it is the whole argument for the second
      # delivery mode: upstream was 17.2.12 (released 2026-08-09) while the newest of the two AUR
      # packages sat at 17.2.3, and BOTH list an `omp-updater` bot as co-maintainer. Automation in
      # the packaging loop did not keep them within ten patch releases of upstream. A host that
      # wants this tool current uses `nixagent.home.upstream`, not the AUR.
      upstream = {
        kind = "installer";
        url = "https://omp.sh/install";
        runner = "sh";

        # `--binary` IS LOAD-BEARING, and this is the finding that made `args` a field. The
        # installer's DEFAULT branch is not deterministic about WHERE it installs (script read
        # 2026-08-10):
        #
        #   bun on PATH, matching arch  -> `bun install -g @oh-my-pi/pi-coding-agent`, which lands
        #                                  in bun's own global prefix ($BUN_INSTALL/bin, i.e.
        #                                  ~/.bun/bin/omp by default)
        #   otherwise                   -> downloads omp-linux-<arch> to
        #                                  "${PI_INSTALL_DIR:-$HOME/.local/bin}/omp"
        #
        # So the destination depends on whether some unrelated tool happens to be installed on the
        # machine, and `installs` -- the idempotency probe -- would be right on one host and wrong
        # on the next, where it would reinstall on every single activation while reporting
        # success. `--binary` forces the second branch, which is the one whose destination this
        # catalogue can actually state. It also skips installing bun as a side effect, which a
        # module that claims to install `omp` has no business doing.
        args = [ "--binary" ];

        installs = ".local/bin/omp";
        # omp-linux-x64: `INTERP /lib64/ld-linux-x86-64.so.2`, same as claude's. Its installer DOES
        # smoke-test, and on failure exits 1 while LEAVING the broken binary in place -- the state
        # lib/install-upstream.sh now clears rather than inheriting on the next activation.
        needsDynamicLoader = true;
      };

      note = ''
        Oh My Pi (github.com/can1357/oh-my-pi, omp.sh) by can1357 -- a terminal AI coding agent
        with a native Rust engine and a Bun/TypeScript frontend, forked from Mario Zechner's
        pi-mono. Command `omp`; AUR package `oh-my-pi-bin`; npm package
        `@oh-my-pi/pi-coding-agent`. Three names, no two of them the same.

        A client by the placement rule, same as `opencode`: it drives whichever remote provider it
        is configured for and loads no weights of its own.
      '';
    };

    qwen-code = {
      arch = "qwen-code";
      binary = "qwen";
      nixpkgs = null;

      # Official upstream Arch `extra`, verified 2026-09-04 through archlinux.org's package API.
      # CachyOS exposes its rebuilt copy from cachyos-extra-v3 as well as the upstream extra entry,
      # so this remains a pacman name on both supported distro answers. The separate AUR
      # `qwen-code-bin` is newer today, but an official repository entry does not belong on the AUR
      # side of an atomic reconcile merely because the release race currently favours it.
      upstream = {
        kind = "installer";
        url = "https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen-standalone.sh";
        runner = "bash";

        # Force the vendor's standalone archive rather than its npm fallback: the archive bundles
        # its private Node runtime and has a deterministic ~/.local layout. `--no-modify-path`
        # prevents the installer appending a block to a home-manager-generated shell rc; PATH is
        # published declaratively by modules/home.nix from `installs` below.
        args = [ "--method" "standalone" "--no-modify-path" ];
        installs = ".local/bin/qwen";

        # The launcher is a shell wrapper around the bundled Linux Node runtime. Inspected from
        # Qwen's v0.23.0 linux-x64 archive on 2026-09-04: that Node executable declares
        # `INTERP /lib64/ld-linux-x86-64.so.2`, so the complete command needs the FHS loader even
        # though the probe path itself begins with a shebang.
        needsDynamicLoader = true;
      };

      note = ''
        Qwen's model-flexible terminal coding agent (github.com/QwenLM/qwen-code). Package and
        catalogue key `qwen-code`; command `qwen`. The upstream plane uses Qwen's official
        standalone-first installer rather than inventing a global npm prefix.
      '';
    };
  };

  # ── Desktop AI clients: graphical applications driving remote frontier models ────────────────
  #
  # Same delivery problem as `cli` above -- fast-moving vendor clients that must never be pinned
  # by nixpkgs -- despite drawing a window instead of running in a terminal. Kept as its OWN group
  # rather than folded into `cli` so that group's documented meaning ("terminal clients driving a
  # remote frontier model") stays true rather than being quietly stretched to also cover an
  # desktop app with a `.desktop` entry. This file's own header explains why that excludes it only
  # from the `cli` group, not from the catalogue.
  desktop = {
    chatgpt-desktop = {
      # Plain Arch and CachyOS package the same official OpenAI application under different names.
      # Verified 2026-08-31:
      #
      #   archlinux.org package search       -> 0 results.
      #   AUR RPC (`chatgpt-desktop`)        -> 26.825.51511-1, current; source is OpenAI's
      #                                          persistent.oaistatic.com Linux .deb.
      #   `pacman -Si chatgpt-desktop-bin`   -> cachyos/26.825.41651-1, URL
      #                                          https://chatgpt.com/download.
      #   CachyOS file database              -> /usr/bin/chatgpt and
      #                                          /usr/share/applications/chatgpt.desktop.
      arch = "chatgpt-desktop";
      archPackageOn.cachyos = "chatgpt-desktop-bin";
      binary = "chatgpt";
      nixpkgs = null;
      aur = true;
      archRepoOn = [ "cachyos" ];

      # OpenAI publishes Linux packages, not a per-user desktop installer script. The home plane
      # intentionally runs vendor scripts only; it does not unpack .deb files into a home prefix.
      upstream = null;

      note = ''
        OpenAI's unified ChatGPT desktop application, including Codex. Catalogue key
        `chatgpt-desktop`; command `chatgpt`. Plain Arch installs AUR package `chatgpt-desktop`,
        while CachyOS installs repository package `chatgpt-desktop-bin`.

        This is separate from the `openai-codex` CLI selection. The CachyOS package provides
        `openai-codex-desktop` without conflicting with the CLI package.
      '';
    };

    claude-desktop = {
      # Official Linux package, verified 2026-08-31:
      #
      #   archlinux.org package search   -> 0 results.
      #   AUR RPC                        -> claude-desktop 1.40609.0-1, current; source is
      #                                      downloads.claude.ai's official Linux .deb.
      #   `pacman -Si claude-desktop`    -> cachyos/1.40609.0-1, URL
      #                                      https://claude.ai/download.
      #   CachyOS file database          -> /usr/bin/claude-desktop and
      #                                      /usr/share/applications/com.anthropic.Claude.desktop.
      arch = "claude-desktop";
      binary = "claude-desktop";
      nixpkgs = null;
      aur = true;
      archRepoOn = [ "cachyos" ];

      # Anthropic publishes Linux packages, not a per-user installer script. As with ChatGPT, the
      # home plane does not invent a .deb extraction mode.
      upstream = null;

      note = ''
        Anthropic's official Claude desktop application: Chat, Cowork, and Claude Code in one
        window. Package and catalogue key `claude-desktop`; command `claude-desktop`. It is a
        `desktop` selection because it installs a graphical application and `.desktop` entry;
        nothing here loads a model locally.
      '';
    };

    opencode-desktop = {
      # AUR-only on EVERY distro, verified 2026-09-19:
      #
      #   archlinux.org package search   -> 0 results.
      #   `pacman -Si opencode-desktop` / `-bin` -> no result (no CachyOS repo build either).
      #   AUR RPC (`opencode-desktop-bin`) -> 1.18.31-1, current; source is the fork
      #       github.com/anomalyco/opencode release .deb (linux-amd64/arm64), NOT an
      #       official SST vendor package. Unlike chatgpt-desktop/claude-desktop above,
      #       no vendor Linux package exists to point at.
      #   package() installs launcher `/usr/bin/opencode-desktop` plus upstream
      #       `ai.opencode.desktop` desktop entry (Exec rewritten to the wrapper).
      arch = "opencode-desktop-bin";
      binary = "opencode-desktop";
      nixpkgs = null;
      aur = true;

      # No vendor installer path: the only delivery is the AUR package's fork .deb.
      # The home plane does not unpack .debs into a home prefix.
      upstream = null;

      note = ''
        OpenCode desktop client: sessions, provider keys, and agent runs in one window.
        Catalogue key `opencode-desktop`; AUR package `opencode-desktop-bin` on every
        distro; command `opencode-desktop`. Packaged from community-fork release assets,
        not official vendor packages — re-check provenance before trusting updates.
      '';
    };
  };
}
