# nixagent

**Agentic AI clients — Claude Code, Claude Desktop, ChatGPT Desktop, DeepSeek Harness, Gemini CLI,
Grok Build, Muse Code, Qwen Code, Codex, opencode and omp — declared per host and delivered by whichever of two
planes keeps the tool current: the distro's package manager, or the vendor's own mutable delivery.
Never nixpkgs, because they update themselves.**

## What this is

A platform-neutral catalogue (`lib/agents.nix`) naming each agent client's package identity, its
real command name and its vendor delivery method, plus **two modules for two delivery planes**:

**The distro plane** (`modules/nixagent.nix`, system-manager) resolves a selection into two lists a
host's Arch package reconciler can consume. Two groups: `cli` (terminal binaries) and `desktop`
(graphical applications).

```nix
nixagent.distro = "cachyos";               # or "arch" (the default)
nixagent.cli = [ "claude-code" "deepseek-harness" "gemini-cli" "grok-build" "muse-code" "openai-codex" "opencode" "omp" "qwen-code" ];
nixagent.desktop = [ "chatgpt-desktop" "claude-desktop" "opencode-desktop" ];

nixarch.packages.pacman =
  config.nixagent.archPackages ++ config.nixagent.runtimeArchPackages;
nixarch.packages.aur    = config.nixagent.aurPackages;
```

**The upstream plane** (`modules/home.nix`, home-manager) uses the tool's *own* mutable delivery
method and puts its command on PATH. Usually that runs the vendor installer once; DeepSeek's
documented npx launch gets an unversioned dispatcher and remains npm-owned. This is how a NixOS host gets these
tools at all — *given the host requirement below* — and how any host gets one whose distro package
has fallen behind.

```nix
nixagent.home.upstream = [ "claude-code" "deepseek-harness" "grok-build" "muse-code" "qwen-code" ];
# Selectable: claude-code | deepseek-harness | grok-build | muse-code | omp | openai-codex | opencode | qwen-code
```

That is the whole surface. One top-level option namespace, `nixagent`, like every repo in this
family. The planes are independent and chosen **per host** — pacman/AUR on the Arch boxes, upstream
on NixOS, or upstream everywhere. Neither is forced and neither is the fallback.

## The rule this repo exists for: never nixpkgs — and the reason is not freshness

These tools **ship their own updater** and release on a cadence measured in days. A nix-store path
is read-only, so the updater cannot run at all — the version freezes until a human bumps a
`flake.lock`, and the tool spends the interval telling its operator to update while being
structurally unable to. A distro package is mutable enough that the system's own upgrade *is* the
updater, which is the outcome you want.

**That is the whole argument, and it is the only load-bearing one.** Freshness is a symptom of it,
not a second reason — and treating it as one has already gone wrong here once. Re-measured
2026-08-11 against nixpkgs-unstable HEAD, each project's release feed, and the Arch package API:

| Catalogue entry | nixpkgs-unstable | Arch / AUR | upstream |
|---|---|---|---|
| `claude-code` | 2.1.226 | 2.1.222 (`cachyos`) | 2.1.226 |
| `opencode` | 1.18.13 | 1.18.16 (`extra`) | 1.18.16 |
| `openai-codex` | 0.147.0 | 0.146.1 (`extra`) | 0.147.0 |
| `gemini-cli` | 0.47.0 | 1:0.50.0 (`extra`) | 0.54.4 |
| `omp` | *absent* | 17.2.2 (AUR, flagged out of date) | 17.2.12 |
| `grok-build` | 1.0.5 | 1.0.13 (AUR) | 1.0.13 |
| `qwen-code` | 0.16.0 | 0.21.2 (`extra`) | 0.23.0 |
| `deepseek-harness` | *absent* | 0.1.2rc.1 (AUR) | 0.1.2-rc.1 |
| `muse-code` | *absent* | 1.0.1.r2006.1 (AUR) | 1.0.1-R2006.1 |

Read the original five honestly: nixpkgs is **ahead** of Arch for two and level for a third. An
earlier revision of this README claimed every entry was behind its distro package. That was true of
the snapshot it was taken from and is false now — which is exactly why the rule does not rest on it.
Freshness changes hands week to week; immutability does not.

The one row that *is* catastrophic is `gemini-cli`, and it is not a packaging lag: nixpkgs marked
the package with a `meta.problems.removal` note on 2026-08-07 recording that Google is replacing
Gemini CLI with Antigravity CLI. A package being wound down is not evidence about nixpkgs' cadence.

(`omp` is the one entry nixpkgs genuinely does *not* carry — neither `omp` nor `oh-my-pi` exists
there, force-evaluated 2026-08-10. What does exist is `pkgs.pi-coding-agent` 0.83.0, homepage
`pi.dev`, main program `pi`: Mario Zechner's pi-mono, the project omp forked *from*. Reaching for it
because the npm name is `@oh-my-pi/pi-coding-agent` installs a different agent under a different
command.)

The catalogue therefore carries **`nixpkgs = null` on every entry**, present rather than omitted so
that nobody mistakes the policy for an oversight, and `checks/agents-eval.nix` asserts it — an
addition that names a real nixpkgs attribute fails `nix flake check`. There is **no `nixosModules`
output**: not a gap to fill later, but the boundary the repo was drawn for. A NixOS host that wants
these tools uses the upstream plane below, which installs the vendor's own build and leaves its
updater working.

### What "never nixpkgs" does *not* mean

The prohibition is on nix owning the **tool**. It says nothing about nix supplying that tool's
**runtime** or its installer's dependencies. `programs.nix-ld` providing a dynamic loader,
`nixagent.home.extraPath` handing a delivery process its required commands, Codex's declarative
`bubblewrap`, and DeepSeek Harness's Node/pnpm runtime are not exceptions to the rule — they are the rule working. Nix
builds the ground the vendor's artifact stands on; the artifact stays the vendor's, mutable, and
updatable by its own updater.

### Codex sandbox prerequisite

On Linux, selecting `openai-codex` also selects the distribution's `bubblewrap` package. Codex uses
the first `bwrap` on `PATH`; without it, the client warns and falls back to a bundled helper whose
operation depends on unprivileged user namespaces. The declared package is the reliable setup
recommended by the [official sandbox prerequisites](https://developers.openai.com/codex/concepts/sandboxing#prerequisites).

- Distro plane: `nixagent.runtimeArchPackages = [ "bubblewrap" ]`, wired into pacman beside
  `archPackages`.
- Upstream/home-manager plane: `pkgs.bubblewrap` enters `home.packages`; Codex itself remains
  installed by the vendor and absent from the Nix store.

## The second delivery mode, and the measurement that forced it

The argument above is about nixpkgs and it holds. What it does *not* establish is that a distro
package is always current — and the same table shows it measurably is not. `omp` is ten patch
releases behind upstream in the AUR, with an `omp-updater` bot listed as co-maintainer on *both*
packages and both flagged out of date; `opencode` and `gemini-cli` trail their own releases in
Arch `extra`. A packager — even an automated one — is a human in the loop of a project that ships
several times a week, and for a fast enough project the AUR pins as badly as nixpkgs would.

So there is a second plane, and its contract is one sentence:

> **Nix ensures the tool exists and is on PATH. Nix never owns it.**

No agent client payload in `home.packages`, no `home.file` for a binary, no hash and no version
anywhere — `checks/home-eval.nix` asserts that boundary. Distro-owned runtime such as Codex's
`bubblewrap` or DeepSeek's Node/pnpm may be in `home.packages`; the agent itself never is.
Installer-delivered clients retain their own updater. The DeepSeek exception is explicit rather
than disguised: a tiny `dsh` dispatcher runs the official unversioned `npx @deepseek-ai/dsh`
invocation, and npm owns the payload and cache.

The two modes answer different questions, and neither wins globally:

| | distro plane | upstream plane |
|---|---|---|
| Updates via | `pacman -Syu`, with the host's other packages | the tool's own updater, or npm resolution for npx delivery |
| Freshness bounded by | a packager | the vendor's own release |
| Needs | a package manager and (for AUR) a helper | a `$HOME`, method-specific tools, and sometimes **a dynamic loader** |
| Works on NixOS | no | yes — *only with `programs.nix-ld`*, see below |
| Removes cleanly | **yes** — pacman owns the files | **no** — nothing owns the files |

That last row is the honest cost: deselecting a tool on the upstream plane leaves the binary
exactly where it was. Full write-up:
[`studies/the-aur-lags-upstream-too.md`](studies/the-aur-lags-upstream-too.md).

### Host requirement: a dynamic loader for foreign binaries

Four of the six shell installers deliver an **x86-64 glibc executable** declaring
`INTERP /lib64/ld-linux-x86-64.so.2`, a path NixOS does not have.

So on NixOS the upstream plane needs `programs.nix-ld`, and needs it *configured*, not merely
enabled — a host with nix-ld in the closure but nothing behind it installs a **stub** at that path
whose entire job is to refuse. That state passes a naive existence check and fails at run time, so
`lib/install-upstream.sh` tests for it by name and aborts in `stage: preflight` with the option to
set, before anything is downloaded.

```nix
programs.nix-ld.enable = true;
programs.nix-ld.libraries = with pkgs; [ stdenv.cc.cc.lib zlib openssl ];
```

Claude's installer cannot route around this by picking its musl build: its libc detection is
`[ -f /lib/libc.musl-*.so.1 ] || ldd /bin/ls | grep -q musl`, and NixOS has no `/bin/ls`, so it
selects the glibc artifact on exactly the hosts that cannot run it.

**It is per entry, and `openai-codex` is why.** The catalogue field is `needsDynamicLoader` — named
after the host requirement, not after the artifact, because codex ships the *largest* native binary
here (a 258 MB Rust executable) and needs no loader at all: every Linux asset is
`x86_64-unknown-linux-musl`, and its program headers carry no `INTERP` segment. Grok Build's
released Linux binary is static PIE too. Both start on bare NixOS. Flagging either by "is this a
native binary" would have imposed a prerequisite it does not have and refused installs that would
have worked.

### How idempotency and failure work

One `test -x` on the vendor's own launcher path, per selected tool, per activation. Present →
nothing is fetched, nothing is printed, no subprocess runs. That is the entire cost on a machine
that already has the tool, and it also protects the tool's self-updates: re-running a vendor
installer over a self-updated install is how a current tool gets rolled *back*.

When the tool is absent, the installer is downloaded **to a file** and only then run — never
`curl | sh`, because a pipeline's exit status is its last command's, so a failed fetch is handed to
a shell that reads nothing and exits 0. A zero exit from the installer is then not treated as
evidence of anything: the expected path must exist, be executable, and answer `--version` before
the activation is allowed to succeed. Each stage failure prints a labelled block naming the stage,
the installer's own output and the fact that the command is unavailable, and by default fails the
switch (`nixagent.home.onInstallFailure = "warn"` downgrades it for a laptop that switches
offline — quieter, never silent).

Full reasoning, including what each vendor installer actually does:
[`studies/upstream-installers-disagree-about-everything.md`](studies/upstream-installers-disagree-about-everything.md).

## Why these are not nixllm's, and not nixsh's

Package delivery in this family is split by **domain**, and these clients had no owner.

**Not [nixllm](https://github.com/corbet-nix/nixllm-corbet-ch).** That repo *serves* models — a
broker, an inference engine, a model store, a GPU. Everything here, `desktop` group included, is an
HTTPS client that never loads a weight and has no opinion about a GPU. Same project space, opposite
side of the wire, and a shared catalogue would mean one repo whose entries need two unrelated kinds
of host to be useful.

**Not [nixsh](https://github.com/corbet-nix/nixsh-corbet-ch)**, despite most of these being
terminal tools. nixsh is universal *by construction* — every host has a shell and reaches for a
terminal tool, which is exactly why that catalogue has no per-host story to build. These do not have that
property and must not inherit it: a small production server has a shell and wants `ripgrep`, and
emphatically does not want a self-updating agent CLI and its runtime. "Runs in a terminal" is a
shape; nixsh's claim is the *domain* "every host needs this", and these fail it.

The placement rule, stated in `lib/agents.nix`'s own header so the next candidate is decidable
rather than argued:

> Does the tool drive a remote frontier model it does not host, delivered as a package that
> self-updates faster than nixpkgs tracks it? Yes → here, catalogued as `cli` or `desktop` by
> whichever interface it actually has. No → whichever repo owns the thing it actually is.

Whether the tool opens a terminal or a window is *not* the eligibility test. It only decides
whether the selection belongs in `cli` or `desktop`.

## The AUR/pacman split, and why it is not the same answer on every host

`pacman -S` resolves a transaction **atomically**: one unresolvable target aborts the whole
converge with `target not found` and takes every unrelated package in the same list down with it.
So `archPackages` and `aurPackages` are separate outputs, and that they never intersect is the
load-bearing invariant `checks/` exists to hold.

Several entries make this harder than it looks. `claude-code`, `claude-desktop`, and
`chatgpt-desktop` are in no upstream Arch repository, but they are in the AUR and CachyOS carries
repository builds. ChatGPT adds one more wrinkle: its AUR name is `chatgpt-desktop`, while the
CachyOS package is `chatgpt-desktop-bin`.

The two errors are not symmetric, so the design follows the asymmetry:

- `aur = true` is the **floor** for anything upstream Arch does not package — the direction that
  cannot abort a transaction, since an AUR helper resolves repository packages first and builds
  nothing that did not need building.
- `archRepoOn = [ "cachyos" ]` lifts it to the pacman list, but only on a distro whose own
  repository is known to carry it.
- `archPackageOn.cachyos` records a different derivative package name when one exists; it never
  changes the plain-Arch/AUR floor.
- `nixagent.distro` defaults to `"arch"`, the recoverable answer, rather than to whichever distro
  the catalogue happened to be written on.

Write-up with the full evidence:
[`studies/claude-code-is-not-in-arch-official-repos.md`](studies/claude-code-is-not-in-arch-official-repos.md).

## Package name ≠ command name ≠ catalogue key

Package name, command, and catalogue key are separate identities, so `nixagent.binaries` publishes
the mapping. Pointing a launcher at a package name is wrong for several entries.

| Selection (catalogue key) | pacman package | command | vendor installer |
|---|---|---|---|
| `claude-code` | `claude-code` | `claude` | `claude.ai/install.sh` → `~/.local/bin/claude` |
| `deepseek-harness` | `deepseek-harness-bin` | `dsh` | `npx @deepseek-ai/dsh` via `~/.local/bin/dsh` dispatcher |
| `gemini-cli` | `gemini-cli` | `gemini` | — (npm/Node only; no installer, and no Linux release asset in any of the last 15 releases) |
| `grok-build` | `grok-build` | `grok` | `x.ai/cli/install.sh` → `~/.grok/bin/grok` |
| `muse-code` | `muse-code-bin` | `muse` | `dev.meta.ai/install.sh` → `~/.local/bin/muse` |
| `openai-codex` | `openai-codex` | `codex` | `chatgpt.com/codex/install.sh` → `~/.local/bin/codex` |
| `opencode` | `opencode` | `opencode` | `opencode.ai/install` → `~/.opencode/bin/opencode` |
| `omp` | `oh-my-pi-bin` | `omp` | `omp.sh/install` → `~/.local/bin/omp` |
| `qwen-code` | `qwen-code` | `qwen` | Qwen standalone installer → `~/.local/bin/qwen` |
| `chatgpt-desktop` | Arch: `chatgpt-desktop`; CachyOS: `chatgpt-desktop-bin` | `chatgpt` | — (vendor Linux packages, no per-user installer script) |
| `claude-desktop` | `claude-desktop` | `claude-desktop` | — (vendor Linux packages, no per-user installer script) |
| `opencode-desktop` | `opencode-desktop-bin` (every distro) | `opencode-desktop` | — (community-fork release .deb via AUR, no vendor package; re-check provenance on updates) |

`omp` is the sharpest case and the reason the key is documented as naming the **tool**: the project
calls itself `omp`, the AUR calls it `oh-my-pi-bin`, npm calls it `@oh-my-pi/pi-coding-agent`, and
the command is `omp`. Four names, no two the same. The key cannot be "the pacman name" now that it
is also what a consumer writes on the home-manager plane, where the AUR does not exist and a `-bin`
suffix means nothing.

`upstream = null` is a **recorded finding**, not a blank — each such entry carries what was checked.
`nixagent.home.upstream` is typed to entries that have a supported vendor delivery path, so naming
one that does not is an eval error rather than an activation that quietly fetches nothing. The one
npx entry is explicit and narrow: DeepSeek itself documents that invocation; it is not a generic
license to turn every npm package into an invented global install.

**A finding is not a verdict — re-probe it.** `openai-codex` carried `upstream = null` from
2026-08-07 to 2026-08-11 on a recorded *403 from `openai.com/codex/install.sh`*. That URL is not
OpenAI's and never served the installer; the real one is in the project README and answers 200. A
403 is a fact about a URL, and reading it as a fact about a tool kept codex off every NixOS host
here for four days. When an entry blocks a host, check the vendor's own documented command before
concluding the vendor ships nothing.

## The brain: one knowledge store, one skill library, every client

`nixagent.brain` (`homeManagerModules.brain`) connects every agent client in a home to ONE shared
knowledge store. Above all it wires ONE skill library into every client, by reference and never
by copy, so a skill edited in the store is the skill every client loads:

```nix
nixagent.brain = {
  enable = true;
  skills = "/home/alice/brain/skills";          # <name>/SKILL.md, the one library
  claude.instructions = "@~/brain/AGENTS.md";   # ~/.claude/CLAUDE.md
  claude.memoryDir = "/home/alice/brain/memory/$(uname -n)";
  codex.instructions = builtins.readFile ./codex-agents.md;  # ~/.codex/AGENTS.md
  # refresh = "5min";  # user timer re-linking the library; null disables it
};
```

Where each client reads skills was measured with a probe skill (2026-09-26): Claude Code reads
`~/.claude/skills` only; Codex, opencode and Grok Build read the tool-neutral `~/.agents/skills`
from the home. Every library skill is linked into both, **one link per skill**: both folders also
hold content the tools install themselves (Claude Code's `synced/` account skills, other tools'
own skills), which a whole-folder link would pour into the shared library. Real directories are
never touched, links to deleted skills are pruned, and Codex's own duplicate links into the
library are removed. The timer carries new and deleted skills to every client within `refresh`.

Containers without home-manager (an agent-orchestration pod running vendor images) use the same
wiring through `lib.brain` (`all`, `skillsOnly`, `claude`, `agents`, `codex`), which returns plain
POSIX sh with no store paths. `checks/brain-links.nix` runs it against a scratch home.

## Paperclip: an agent company, declared

`nixidyModules.paperclip` (`nixagent.paperclip`) renders a [Paperclip](https://github.com/paperclipai/paperclip)
server for Argo CD **and** the organisation it runs: companies, agents (role, manager, adapter,
model, instructions), and API-key tool connections. A reconciler sidecar keeps the live instance
matching the declaration through Paperclip's API: **declared is enforced, undeclared is reported**,
so agents may still hire and the declaration catches up by a human decision. `reconciler.mode =
"report"` writes nothing and prints every intended change.

The pod is the agents' workstation. Every agent runs on the pod's real home (no Paperclip-managed
AI logins, which give each run a throwaway home), wired to the shared knowledge store through
`lib.brain` — the same snippets `nixagent.brain` runs on every host. Each company's managed-skill
directory is a read-write bind mount of the one skill library, so skills created in Paperclip land
in the library and library edits reach the next run; the reconciler keeps each company's listing
current. Two traps it encodes: Claude agents want `adapterConfig.engine = "cli"` (the default ACP
engine does not load the home's skills), and Paperclip refuses any `Host` but its own, so probes
and the reconciler send it. `examples/paperclip/values.nix` shows every option;
`checks.paperclip-renders` renders it.

## What this does not own

- **Configuration of the agents themselves** — API keys, model choice, MCP servers, permission
  rules. This repo delivers binaries and publishes names. That it now *has* a home-manager module
  does not change this: `modules/home.nix` exists because an installer needs a user and a `$HOME`,
  not because agent configuration moved in. Per-user agent config lives wherever the consumer
  already keeps it, and `nixagent.home.binaries`/`paths` are published so it can point at the real
  command instead of guessing it from a package name.
- **Updating client payloads.** On the distro plane that is `pacman -Syu`'s job; on the upstream
  plane it is the tool's own updater, or npm's mutable resolution/cache for the documented npx
  method. Nothing here re-runs a shell installer over a tool that is already present.
- **Removing anything from the upstream plane.** Nothing owns those files, so deselecting a tool
  leaves the binary in place. Stated plainly rather than papered over — the distro plane does not
  have this limitation, and that is a real reason to prefer it on a host that has a reconciler.
- **Local inference of any kind** — engines, model runners, weight converters. Those load weights,
  which is nixllm's domain by the boundary above, not a matter of taste.

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | Flake entry point: `systemManagerModules`, `homeManagerModules`, `lib.catalogue`, `lib.policy`, `checks`. No `nixosModules` — see above. |
| `lib/agents.nix` | The catalogue: one entry per agent client, with its pacman name, command, AUR status, vendor installer, runtime prerequisites, and the policy `nixpkgs = null` for the client itself. |
| `lib/install-upstream.sh` | The upstream plane's shell half: sourceable functions that probe and verify shell-installer and npx delivery. Inlined into the activation script by `modules/home.nix` and executed for real by `checks/upstream-install.nix` — one implementation, not a copy. |
| `modules/nixagent.nix` | Distro plane: options, catalogue resolution, and the published `archPackages`/`aurPackages`/`binaries`. Also *is* the Arch backend — there is nothing platform-specific left for a second file to hold. |
| `modules/home.nix` | Upstream plane: `nixagent.home.*`, one activation entry, `home.sessionPath`, and the published `binaries`/`paths`/`prefixes`. |
| `checks/agents-eval.nix` | The distro plane and the catalogue's own shape, via `lib.evalModules`. |
| `checks/home-eval.nix` | The upstream plane's rendering, via `lib.evalModules` against a stub of the home-manager options it writes to. |
| `checks/upstream-install.nix` + `.sh` | The only check that **runs** something: `lib/install-upstream.sh` shellchecked, then executed against a stubbed `curl` through eleven cases. |
| `experiments/verify-package-names.sh` | Hand-run verification of every name against upstream Arch, the AUR (with out-of-date flags) and the local pacman, plus a live fetch of every vendor installer URL. |
| `studies/` | Written-up findings that changed a decision here. |

## Platform support

**Arch / CachyOS (via system-manager):** the distro plane's target. Publishes package-name lists
for the host's own reconciler; installs nothing itself, because on Arch there is no installer here
to call.

**Any host with home-manager, NixOS included (via home-manager):** the upstream plane. Uses the
vendor's supported mutable delivery and puts the resulting command on PATH. This is the *only*
way these tools arrive on a NixOS host from this repo — `nixosModules` remains deliberately absent,
because it could only mean `environment.systemPackages` of the frozen derivations the nixpkgs rule
refuses.

Both planes can run on the same host for different tools. They share no state — system-manager and
home-manager are separate evaluations with no common `config` — so the one case where they collide
(the same command arriving from both) is reported at activation time, where both are finally
visible, rather than pretended away at eval time.

## Checks

Three, all wired to `nix flake check`.

**`agents-eval`** evaluates `modules/nixagent.nix` via `lib.evalModules` and asserts, among others:
an empty selection resolves to nothing on both lists; every catalogue group (`cli` and `desktop`)
has a matching option and contributes; `archPackages` and `aurPackages` never intersect on *either*
distro setting; every selection lands on exactly one list; every entry still carries
`nixpkgs = null`; every entry carries an `upstream` field whose non-null value names a supported
kind and whose `installs` is relative to `$HOME` and ends in that entry's own `binary`; catalogue keys are unique across groups; `claude-code` moves
between the lists with `nixagent.distro` and is never on both; both desktop apps move from the AUR
on plain Arch to CachyOS's repository; ChatGPT emits the correct different package name on each;
and `omp` stays on the AUR list on every distro setting.

**`home-eval`** evaluates `modules/home.nix` against a stub of the home-manager options it writes
to, and asserts what it renders: one activation entry rather than one per tool, after
`writeBoundary`; every call prefixed with home-manager's dry-run hook, so `home-manager build` can
never install anything; the probe path and command taken from the catalogue rather than the key or
the package name; `--binary` and `--no-modify-path` present where they are load-bearing; codex's
`--env 'CODEX_NON_INTERACTIVE=1'` rendered as one quoted word and on no other entry; the loader
flag emitted per entry and **absent** on codex; each vendor's own prefix on `home.sessionPath`,
deduplicated; a selection with no vendor delivery path refused at eval time while `openai-codex`
is accepted; DeepSeek renders exactly one dry-run-safe npx call for the unversioned official
package; and — mechanising the contract — **no agent client payload in `home.packages`, no
`home.file`, and no client version or hash in the rendered script**. Codex contributes only
`pkgs.bubblewrap`; DeepSeek contributes only Node and pnpm runtime ground.

**`upstream-install`** shellchecks `lib/install-upstream.sh` and then *runs* it against stubbed
`curl` and `npx` programs, including: a shell installer runs when the tool is absent; on a second
activation it invokes curl **zero** times *with the network stubbed to fail*, so even an attempt
would be fatal; a 404 and an HTML error page and a non-zero installer each produce a labelled
diagnostic carrying the installer's own output; an installer that exits 0 having installed nothing
**fails**; a binary that installs but cannot start fails; `--env` values reach the installer's
environment intact (spaces included) while a malformed one is a hard error that fetches nothing;
the installer sees its own destination on `PATH` and therefore writes no shell rc file; `warn` mode
does not abort but still prints; a DeepSeek dispatcher forwards arguments intact and is likewise
idempotent; and failed npm resolution leaves no absorbing executable behind.

Every assertion in all three was confirmed to actually fail when the thing it guards is broken.
For the behaviour suite that was done by mutation: removing the idempotency gate, the
installed-path check, the not-a-script check, the `--version` smoke test, curl's status capture,
and warn mode's early return each trip their own cases and nothing else. On the eval side, dropping
`--binary` from the catalogue, making an `installs` path absolute, adding a `home.packages` entry,
and removing the dry-run hook each trip exactly one named assertion.

## Related projects

Part of the same independently-usable module family:
[nixllm](https://github.com/corbet-nix/nixllm-corbet-ch) (the other side of the wire — serving
models locally, where these only talk to remote ones),
[nixsh](https://github.com/corbet-nix/nixsh-corbet-ch) (the universal terminal-tool catalogue
this repo is deliberately *not* part of), and
[nixarch](https://github.com/corbet-nix/nixarch-corbet-ch) (the Arch package reconciler these
lists are written for).

## Licence

Outbound licence is `MIT OR Apache-2.0`. See `LICENSE-MIT` and `LICENSE-APACHE`; every source file carries `SPDX-License-Identifier: MIT OR Apache-2.0`.
