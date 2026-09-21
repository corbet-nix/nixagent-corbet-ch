# SPDX-License-Identifier: MIT OR Apache-2.0
# shellcheck shell=bash
#
# nixagent -- the UPSTREAM delivery mode, shell half. Defines one function and nothing else, so
# this file is `source`-able: ../modules/home.nix inlines it verbatim into a single home-manager
# activation entry and then calls the function once per selected tool, and ../checks/
# upstream-install.nix sources the SAME file and drives the function directly against a stubbed
# curl. One implementation, exercised by the tests that guard it -- not a copy of it.
#
# ── THE CONTRACT: NIX ENSURES THE TOOL EXISTS, NIX NEVER OWNS IT ───────────────────────────────
#
# Everything below runs the VENDOR's own installer into the VENDOR's own per-user prefix, and then
# gets out of the way. Nothing here writes a version number, a hash, a lock file or a store path,
# and nothing here ever runs a second time on a machine that already has the tool. That is
# deliberate and it is the whole point: these tools ship their own updater, `<tool> update` must
# keep working afterwards, and a nix-managed copy -- read-only store path or not -- takes that
# away. See ../lib/agents.nix's header for the measurements behind the policy, including the ones
# showing the AUR lagging as badly as nixpkgs for a fast-moving entry.
#
# So the post-condition this function enforces is "the command EXISTS and runs", never "the
# command is version X". An operator who wants a specific version runs the tool's own updater.
#
# ── WHY NOT `curl ... | sh` ────────────────────────────────────────────────────────────────────
#
# Every one of these vendors documents `curl -fsSL <url> | sh`. Do not do that from an activation
# script. A pipeline's exit status is its LAST command's, so a failed fetch -- DNS, a captive
# portal, a 404, a proxy returning an error page -- is handed to `sh`, which reads it, finds
# nothing to run, and exits 0. The switch then reports success having installed nothing, which is
# exactly the class of failure these hosts have been bitten by often enough to build a rule around.
# `set -o pipefail` would fix the status but not the "200 OK, here is an HTML error page" case.
#
# Downloading to a file first makes curl's own exit status the answer, and lets the content be
# looked at before it is executed. Both checks are below, and both have a test.
#
# ── THE THREE THINGS THAT ARE VERIFIED AFTER THE INSTALLER RETURNS ─────────────────────────────
#
# An installer exiting 0 is not evidence that anything was installed; it is evidence that nothing
# crashed. So a zero exit is followed by: the expected path exists, it is executable, and it
# answers `--version`. The last one is not paranoia -- omp's own installer does exactly this to
# itself (scripts/install.sh, the SMOKE_OUTPUT block: a musl build downloads fine and then dies
# with relocation errors, so the download succeeding proves nothing). Every catalogued installer's
# binary answers `--version`; a future tool that does not would need a catalogue field for its
# equivalent, and until one exists inventing the field would be speculative surface.
#
# ── REQUIRES bash ──────────────────────────────────────────────────────────────────────────────
#
# Arrays and `local`. Home-manager's activation script is bash, and the check runs it under bash.
# The INSTALLERS are run with whichever interpreter their own shebang and docs specify, which is
# not always bash -- that is the `--runner` argument, per catalogue entry.

# nixagent_install_upstream
#   --name NAME              catalogue key, for messages only
#   --command CMD            the command the tool installs (`claude`, not `claude-code`)
#   --probe REL              installed launcher, RELATIVE TO $HOME -- see the note below
#   --url URL                the vendor's installer
#   --runner bash|sh         interpreter to run it with
#   [--needs-dynamic-loader] what the installer lands requires /lib64/ld-linux-x86-64.so.2 --
#                            preflighted before anything is downloaded. NOT "is it a native
#                            binary": codex's artifact is a static-PIE musl executable with no
#                            INTERP segment and needs no loader at all. See lib/agents.nix.
#   [--env NAME=VALUE]       exported for the installer run only; repeatable
#   [--needs CMD]            a command this installer hard-requires, preflighted by name;
#                            repeatable. See lib/agents.nix's `needs` field for why.
#   [--on-failure abort|warn]  default abort
#   [--connect-timeout N]      default 10  (seconds)
#   [--max-time N]             default 600 (seconds)
#   [-- ARGS...]             flags passed to the installer, from the catalogue entry
#
# `--probe` is relative to $HOME, resolved here at ACTIVATION time, rather than an absolute path
# baked in at eval time. Two reasons, one practical and one structural: the check can point a fake
# HOME at a scratch directory and exercise the real function, and a home-manager evaluation that
# is built on one machine and activated as a different user cannot bake the wrong home in.
#
# Exit status: 0 on success or a skip, 1 on a failed install under `--on-failure abort`, 2 on a
# malformed call. 2 is never downgraded by `--on-failure warn`: a bad argument list is a bug in
# this repo, not a network condition, and hiding it behind a warning would hide the bug.
nixagent_install_upstream() {
  local name="" command_name="" probe_rel="" url="" runner=""
  local on_failure="abort" connect_timeout="10" max_time="600" needs_loader=""
  local -a installer_args=()
  local -a installer_env=()
  local -a needs=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --)
        shift
        installer_args=("$@")
        break
        ;;
      --needs-dynamic-loader)
        needs_loader=1
        shift
        continue
        ;;
      --needs)
        if [ "$#" -lt 2 ]; then
          printf 'nixagent: internal error: --needs requires a value\n' >&2
          return 2
        fi
        needs+=("$2")
        shift 2
        continue
        ;;
      --env)
        if [ "$#" -lt 2 ]; then
          printf 'nixagent: internal error: --env requires a value\n' >&2
          return 2
        fi
        # NAME=VALUE, validated here rather than trusted. A bare `--env FOO` would otherwise reach
        # `env` as a COMMAND to execute rather than an assignment, which fails as "FOO: No such
        # file or directory" from inside an install and reads like a broken installer.
        case "$2" in
          [A-Za-z_]*=*) ;;
          *)
            printf 'nixagent: internal error: --env expects NAME=VALUE, got %s\n' "$2" >&2
            return 2
            ;;
        esac
        installer_env+=("$2")
        shift 2
        continue
        ;;
      --name | --command | --probe | --url | --runner | --on-failure | --connect-timeout | --max-time)
        if [ "$#" -lt 2 ]; then
          printf 'nixagent: internal error: %s requires a value\n' "$1" >&2
          return 2
        fi
        case "$1" in
          --name) name="$2" ;;
          --command) command_name="$2" ;;
          --probe) probe_rel="$2" ;;
          --url) url="$2" ;;
          --runner) runner="$2" ;;
          --on-failure) on_failure="$2" ;;
          --connect-timeout) connect_timeout="$2" ;;
          --max-time) max_time="$2" ;;
        esac
        shift 2
        ;;
      *)
        printf 'nixagent: internal error: unknown argument %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  local missing=""
  [ -n "$name" ] || missing="$missing --name"
  [ -n "$command_name" ] || missing="$missing --command"
  [ -n "$probe_rel" ] || missing="$missing --probe"
  [ -n "$url" ] || missing="$missing --url"
  [ -n "$runner" ] || missing="$missing --runner"
  if [ -n "$missing" ]; then
    printf 'nixagent: internal error: missing required argument(s):%s\n' "$missing" >&2
    return 2
  fi

  case "$on_failure" in
    abort | warn) ;;
    *)
      printf 'nixagent: internal error: --on-failure must be abort or warn, got %s\n' "$on_failure" >&2
      return 2
      ;;
  esac

  if [ -z "${HOME:-}" ]; then
    printf 'nixagent: %s: internal error: HOME is unset, so the per-user prefix cannot be resolved\n' "$name" >&2
    return 2
  fi

  local probe="$HOME/$probe_rel"

  # ── THE IDEMPOTENCY GATE ────────────────────────────────────────────────────────────────────
  #
  # One `test -x` per selected tool per activation, and on a machine that already has the tool
  # that is the ENTIRE cost of this module: no network, no subprocess, no output. An activation
  # step that fetches on every switch would be a regression rather than a feature, and it would
  # also fight the tool's own updater -- re-running a vendor installer over a self-updated install
  # is how a working tool gets rolled back to whatever the installer's "latest" thinks today.
  #
  # `-x` and not `-e`: it follows symlinks, so the dangling-symlink case (a version directory
  # pruned out from under `~/.local/bin/claude`) reads as absent and gets repaired, which is the
  # behaviour wanted. It is also deliberately NOT `command -v`: resolving the name anywhere on
  # PATH would let a distro-packaged copy from the pacman/AUR plane satisfy the probe, and those
  # two planes are chosen per host precisely so they do not have to agree.
  if [ -x "$probe" ]; then
    return 0
  fi

  printf 'nixagent: %s: %s is absent -- installing from %s\n' "$name" "$probe" "$url"

  # The one place the two delivery planes can collide, reported rather than resolved. Nix cannot
  # see it at eval time -- the pacman/AUR plane is a system-manager evaluation and this is a
  # home-manager one, two separate option trees with no shared `config` to read across -- so it is
  # caught here, at the only moment both are visible. Not fatal: a per-user install shadowing a
  # distro one is a legitimate thing to want, and it is what a $HOME-first PATH will do.
  local shadowed=""
  shadowed="$(command -v "$command_name" 2>/dev/null)" || shadowed=""
  if [ -n "$shadowed" ]; then
    # Single quotes around the command name, not backticks: this is a single-quoted printf format
    # and shellcheck reads a backtick in one as an unexpanded command substitution (SC2016). The
    # check in ../checks/upstream-install.nix runs shellcheck over this file precisely because it
    # is inlined into a real activation script, so the warning is fixed rather than suppressed.
    printf "nixagent: %s: NOTE -- '%s' already resolves to %s (another delivery plane, probably a distro package). The upstream install will shadow it wherever %s comes first on PATH.\n" \
      "$name" "$command_name" "$shadowed" "$(dirname "$probe")" >&2
  fi

  local stage="" detail="" rc=0
  local tmpdir="" log=""

  # Single-exit block: every failure sets `stage`/`detail` and breaks to the one reporting site
  # below, so there is exactly one place that formats a diagnostic and exactly one place that
  # decides abort-vs-warn. `cmd || rc=$?` throughout rather than `if ! cmd`, for two reasons: the
  # `||` puts the command in a tested context so an enclosing `set -e` (home-manager's activation
  # script has one) cannot abort before the diagnostic is built, and `$?` after a bare `if ! cmd`
  # is the status of the NEGATION, i.e. 0, which would report every failure as "exited 0".
  while :; do
    # PATH inside an activation is NOT a login shell's PATH, and that is the trap these two checks
    # exist for. On a distro with an FHS the ambient `/usr/bin` makes both of these free, so the
    # gap is invisible until the first host without one -- where `curl` and the runner are simply
    # absent and the failure surfaces as "exited 127" from something that looks like a network
    # problem. `nixagent.home.extraPath` is what a consumer sets to close it.
    if ! command -v curl >/dev/null 2>&1; then
      stage="preflight"
      detail="curl is not on PATH, and every catalogued installer needs it (they fetch their own payloads with it too). If this is a NixOS/nix-managed home, set nixagent.home.extraPath to a list of directories carrying curl and the runner -- an activation script does not inherit a login shell's PATH"
      break
    fi

    # The runner, checked for the same reason and separately: `bash` being absent is a different
    # fault from `curl` being absent, and reporting them as one would send a reader to the network.
    if ! command -v "$runner" >/dev/null 2>&1; then
      stage="preflight"
      detail="the installer's runner '$runner' is not on PATH. This is not a network fault -- see nixagent.home.extraPath"
      break
    fi

    # `env`, third and separately, because the installer is invoked THROUGH it (see the PATH-prepend
    # block below). Without this the missing-coreutils case would surface as "the installer exited
    # 127" -- a diagnostic pointing at the vendor's script, which ran fine and was never reached.
    if ! command -v env >/dev/null 2>&1; then
      stage="preflight"
      detail="coreutils' 'env' is not on PATH, and the installer is invoked through it. This is not a network fault -- see nixagent.home.extraPath"
      break
    fi

    # ── THE PER-ENTRY TOOLS ─────────────────────────────────────────────────────────────────
    #
    # Same reasoning as the three above, one level down: those are what THIS function needs, these
    # are what a particular VENDOR's script needs, named in its catalogue entry. Checked here for
    # the same reason and with the same payoff -- a missing one otherwise surfaces as whatever the
    # installer says when its own pipeline collapses, and what codex says is "Could not parse
    # releases.openai.com release metadata", which blames a CDN for a missing awk.
    #
    # Reported one at a time and by name, with the entry that asked for it, because a list of
    # everything wrong is less useful than the first thing to fix.
    # `if [ -n ... ]` and not `[ -n ... ] && break`: home-manager's activation script runs under
    # `set -e`, where an AND-list whose FIRST command fails is itself a failed top-level command
    # and aborts the whole activation. That would turn "this entry needs nothing extra" -- the case
    # for three of the four -- into a switch that dies with no message at all.
    local need=""
    for need in ${needs[@]+"${needs[@]}"}; do
      if ! command -v "$need" >/dev/null 2>&1; then
        stage="preflight"
        detail="'$need' is not on PATH, and $name's installer requires it (lib/agents.nix records why on the entry). This is not a network fault and not a vendor outage -- see nixagent.home.extraPath"
        break
      fi
    done
    if [ -n "$stage" ]; then
      break
    fi

    # ── THE DYNAMIC LOADER ──────────────────────────────────────────────────────────────────
    #
    # Only for entries flagged `--needs-dynamic-loader`. Gating it matters in both directions: a
    # host with no loader runs a SHELL-script installer perfectly well, so testing unconditionally
    # would refuse installs that would have succeeded. (Found the honest way -- the check harness in
    # ../checks/upstream-install.nix drives fake shell installers inside a nix sandbox, which has
    # no FHS, and an unconditional test failed 25 of its 48 cases.)
    #
    # THE FLAG IS ABOUT THE REQUIREMENT, NOT ABOUT THE ARTIFACT, and the distinction is not
    # academic: three of the four catalogued installers deliver an x86-64 GLIBC executable
    # reporting `INTERP /lib64/ld-linux-x86-64.so.2` (verified by range-fetching the release
    # artifacts), while codex delivers the largest native binary of the lot as a static-PIE musl
    # build with no INTERP segment at all -- it starts fine on a host with no FHS and no nix-ld.
    # Flagging it by "is it native" would have imposed a prerequisite it does not have.
    #
    # For the three that do need it: a distribution that does not provide that path cannot run
    # them, and the failure surfaces as ENOENT on the LOADER, which the shell reports as "no such
    # file or directory" naming a binary that plainly exists -- one of the least legible errors in
    # Unix, and worth spending a preflight to never see.
    #
    # NixOS is the case this is written for: it has no FHS, so the path is absent unless
    # `programs.nix-ld.enable` is set. Checking existence alone is NOT enough. Merely having nix-ld
    # in the closure installs a STUB at that path whose only job is to refuse and print an
    # explanation; the real loader is behind `NIX_LD`, and if that is unset the stub is all there
    # is. So an unconfigured NixOS host passes a naive `[ -e ]` and fails anyway, later, after a
    # download and with a worse message.
    #
    # Both halves are therefore tested, and only the two unambiguous states fail: the path is
    # missing entirely, or it resolves to nix-ld's stub with no `NIX_LD` behind it. Anything else
    # is left alone -- this preflight's job is to catch hosts that provably cannot run the artifact,
    # not to audit hosts that probably can.
    #
    if [ -n "$needs_loader" ] && [ ! -e /lib64/ld-linux-x86-64.so.2 ]; then
      stage="preflight"
      detail="this host has no /lib64/ld-linux-x86-64.so.2, and the installer delivers a native glibc binary that cannot start without it. On NixOS set programs.nix-ld.enable = true (with programs.nix-ld.libraries populated), or deliver this tool through a distro plane instead"
      break
    fi
    if [ -n "$needs_loader" ] && [ -z "${NIX_LD:-}" ] && case "$(readlink -f /lib64/ld-linux-x86-64.so.2 2>/dev/null)" in *stub-ld*) true ;; *) false ;; esac; then
      stage="preflight"
      detail="/lib64/ld-linux-x86-64.so.2 is nix-ld's stub and NIX_LD is unset, so the stub will refuse to load anything. programs.nix-ld.enable is on but nothing is behind it -- populate programs.nix-ld.libraries, and make sure NIX_LD reaches this activation's environment"
      break
    fi

    tmpdir="$(mktemp -d)" || tmpdir=""
    if [ -z "$tmpdir" ] || [ ! -d "$tmpdir" ]; then
      stage="preflight"
      detail="could not create a temporary directory"
      break
    fi
    log="$tmpdir/output"
    : >"$log"

    # Fetch to a FILE. See this file's header for why not `curl | sh`.
    rc=0
    curl -fsSL --connect-timeout "$connect_timeout" --max-time "$max_time" \
      -o "$tmpdir/installer" "$url" 2>"$log" || rc=$?
    if [ "$rc" -ne 0 ]; then
      stage="download"
      detail="curl exited $rc fetching the installer (22 = HTTP error such as 404, 28 = timed out after ${max_time}s, 6/7 = DNS or connection refused)"
      break
    fi

    if [ ! -s "$tmpdir/installer" ]; then
      stage="download"
      detail="the installer downloaded as an empty file"
      break
    fi

    # A 200 response is not proof of a script. Captive portals, proxies and CDN error pages all
    # answer 200 with HTML, which `curl -f` cannot reject and `sh` would happily "run".
    local firstline=""
    IFS= read -r firstline <"$tmpdir/installer" || firstline=""
    case "$firstline" in
      '#!'*) ;;
      *)
        stage="download"
        detail="what came back does not start with a #! line, so it is not a shell script"
        # The head of the response goes into the diagnostic, because the useful part of an error
        # page is rarely its first line -- `<!DOCTYPE html>` says nothing, the `<title>502 Bad
        # Gateway</title>` two lines down says everything. Bounded, so a large binary body cannot
        # flood the switch output.
        head -n 5 "$tmpdir/installer" >>"$log" 2>/dev/null || true
        break
        ;;
    esac

    # ── THE INSTALLER'S OWN PREFIX GOES ON ITS PATH ─────────────────────────────────────────
    #
    # Every one of these installers checks whether its destination is on `$PATH` and, if it is not,
    # EDITS A SHELL RC FILE to put it there. Two of them can be told not to (`--no-modify-path`,
    # `--binary`); codex cannot -- its `add_to_path` returns early only when `$BIN_DIR` is already
    # in `$PATH`, and otherwise writes a marker block into ~/.bashrc, ~/.zshrc or ~/.profile
    # depending on `$SHELL`. There is no flag and no environment variable to suppress it.
    #
    # An activation inherits no login PATH (see the preflight above), so the destination is never
    # on it and the edit always fires -- into a file home-manager may well generate, on a plane
    # whose entire claim is that it does not touch anything nix owns. Telling the installer the
    # truth is both the fix and the honest thing to say: the directory IS on the user's PATH,
    # because `nixagent.home.addToPath` put it there through `home.sessionPath`.
    #
    # Scoped to this one command rather than exported: nothing after it needs the change, and the
    # loader/curl preflights above deliberately ran against the unmodified PATH.
    #
    # `${arr[@]+...}` so an empty array is not an unbound-variable error under `set -u`.
    rc=0
    env "PATH=$(dirname "$probe")${PATH:+:$PATH}" \
      ${installer_env[@]+"${installer_env[@]}"} \
      "$runner" "$tmpdir/installer" ${installer_args[@]+"${installer_args[@]}"} >"$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      stage="install"
      detail="the installer exited $rc"
      break
    fi

    # ── EXIT 0 IS NOT EVIDENCE OF AN INSTALL ──────────────────────────────────────────────────
    if [ ! -e "$probe" ]; then
      stage="verify"
      detail="the installer exited 0 but $probe does not exist -- it reported success having installed nothing, or it installed somewhere else than lib/agents.nix records"
      break
    fi
    if [ ! -x "$probe" ]; then
      stage="verify"
      detail="$probe exists but is not executable"
      break
    fi

    rc=0
    "$probe" --version >"$tmpdir/version" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      stage="verify"
      detail="$probe was installed but '$command_name --version' exited $rc, so the binary cannot start"
      cat "$tmpdir/version" >>"$log" 2>/dev/null || true
      break
    fi

    local version_line=""
    IFS= read -r version_line <"$tmpdir/version" || version_line="(no output)"
    printf 'nixagent: %s: installed and verified %s -- %s\n' "$name" "$probe" "$version_line"
    break
  done

  if [ -n "$stage" ]; then
    local severity="FAILED"
    if [ "$on_failure" = "warn" ]; then
      severity="WARNING (nixagent.home.onInstallFailure = \"warn\")"
    fi
    {
      printf '\n'
      printf 'nixagent: %s: %s -- upstream install did not complete\n' "$name" "$severity"
      printf '    stage:     %s\n' "$stage"
      printf '    detail:    %s\n' "$detail"
      printf '    installer: %s (run with %s)\n' "$url" "$runner"
      printf '    expected:  %s\n' "$probe"
      if [ -n "$log" ] && [ -s "$log" ]; then
        printf '    ---- installer output ----\n'
        sed 's/^/    /' "$log"
        printf '    --------------------------\n'
      fi
      printf "    the '%s' command is NOT available for this user.\n" "$command_name"
      printf '\n'
    } >&2

    # ── THE FAILED STATE MUST NOT BE ABSORBING ────────────────────────────────────────────────
    #
    # Everything above this function is idempotent by testing `-x "$probe"` and returning early.
    # If a failed run were allowed to leave an executable at `$probe`, that test would pass on the
    # NEXT activation and the install would be skipped -- so a run that failed loudly here would be
    # laundered into a silent success, permanently, with a broken binary in place. No later switch
    # could ever detect or repair it; only a human deleting the file by hand.
    #
    # That state is reachable and not hypothetical. Two of the three upstream installers create it
    # on their own failure path: omp's downloads the binary, chmod +x's it, smoke-tests it and
    # `exit 1`s WITHOUT removing it; opencode's has no smoke test at all, so a truncated or
    # wrong-architecture download lands executable and is only caught by the `--version` probe
    # below. On a host with no dynamic loader for these glibc binaries (see README, "Host
    # requirements") that is the ordinary outcome rather than the rare one.
    #
    # So the artifact goes. Removing it costs one re-download on the next activation; keeping it
    # costs the ability to ever notice again. `rm -f` and not a guarded test: it follows the same
    # convention as the `-x` gate, and a dangling symlink -- a version directory pruned out from
    # under the entry point -- must be cleared too, which `[ -e ]` would report as absent.
    #
    # A binary that installed correctly but whose `--version` cannot start is deleted by this too.
    # That is intended and not collateral: this plane's claim is "installed AND verified", and an
    # unverifiable binary it silently kept would be exactly the claim it must not make.
    rm -f -- "$probe"

    if [ -n "$tmpdir" ]; then rm -rf "$tmpdir"; fi
    if [ "$on_failure" = "warn" ]; then
      return 0
    fi
    return 1
  fi

  if [ -n "$tmpdir" ]; then rm -rf "$tmpdir"; fi
  return 0
}

# Install the command surface for a tool whose VENDOR documents npx as the delivery mechanism.
# This is intentionally not folded into nixagent_install_upstream: an npm package is not a shell
# installer, has no URL/runner pair, and pretending otherwise would weaken all of that function's
# download checks. The dispatcher contains no version or store path; npm owns the fetched payload
# and its mutable cache, while the selected entry's runtime packages provide node/npx/pnpm.
nixagent_install_npx() {
  local name="" command_name="" probe_rel="" package=""
  local on_failure="abort" max_time="600"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name | --command | --probe | --package | --on-failure | --max-time)
        if [ "$#" -lt 2 ]; then
          printf 'nixagent: internal error: %s requires a value\n' "$1" >&2
          return 2
        fi
        case "$1" in
          --name) name="$2" ;;
          --command) command_name="$2" ;;
          --probe) probe_rel="$2" ;;
          --package) package="$2" ;;
          --on-failure) on_failure="$2" ;;
          --max-time) max_time="$2" ;;
        esac
        shift 2
        ;;
      *)
        printf 'nixagent: internal error: unknown npx argument %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  local missing=""
  [ -n "$name" ] || missing="$missing --name"
  [ -n "$command_name" ] || missing="$missing --command"
  [ -n "$probe_rel" ] || missing="$missing --probe"
  [ -n "$package" ] || missing="$missing --package"
  if [ -n "$missing" ]; then
    printf 'nixagent: internal error: missing required npx argument(s):%s\n' "$missing" >&2
    return 2
  fi

  case "$on_failure" in
    abort | warn) ;;
    *)
      printf 'nixagent: internal error: --on-failure must be abort or warn, got %s\n' "$on_failure" >&2
      return 2
      ;;
  esac
  case "$max_time" in
    '' | *[!0-9]*)
      printf 'nixagent: internal error: --max-time must be a positive integer, got %s\n' "$max_time" >&2
      return 2
      ;;
  esac
  if [ "$max_time" -eq 0 ]; then
    printf 'nixagent: internal error: --max-time must be positive\n' >&2
    return 2
  fi

  # The package is written as one bare shell word in the dispatcher. Restrict it to npm package-
  # spec characters rather than attempting to serialize arbitrary shell input into a new script.
  # This admits scoped packages such as @deepseek-ai/dsh and deliberately rejects whitespace,
  # quotes, substitutions and redirections.
  case "$package" in
    *[!A-Za-z0-9@._/+:=-]*)
      printf 'nixagent: internal error: unsafe npx package spec %s\n' "$package" >&2
      return 2
      ;;
  esac

  if [ -z "${HOME:-}" ]; then
    printf 'nixagent: %s: internal error: HOME is unset, so the per-user command path cannot be resolved\n' "$name" >&2
    return 2
  fi

  local probe="$HOME/$probe_rel"
  if [ -x "$probe" ]; then
    return 0
  fi

  printf 'nixagent: %s: %s is absent -- creating dispatcher for npx %s\n' \
    "$name" "$probe" "$package"

  local shadowed=""
  shadowed="$(command -v "$command_name" 2>/dev/null)" || shadowed=""
  if [ -n "$shadowed" ]; then
    printf "nixagent: %s: NOTE -- '%s' already resolves to %s (another delivery plane, probably a distro package). The upstream dispatcher will shadow it wherever %s comes first on PATH.\n" \
      "$name" "$command_name" "$shadowed" "$(dirname "$probe")" >&2
  fi

  local stage="" detail="" rc=0
  local tmpdir="" log="" dispatcher=""
  while :; do
    local need=""
    for need in node npx timeout mkdir chmod mv mktemp; do
      if ! command -v "$need" >/dev/null 2>&1; then
        stage="preflight"
        detail="'$need' is not on PATH, and the $name npx delivery needs it. On a NixOS/nix-managed home, supply Node and coreutils through nixagent.home.extraPath; the client entry's runtime packages keep them on the interactive PATH afterwards"
        break
      fi
    done
    if [ -n "$stage" ]; then
      break
    fi

    tmpdir="$(mktemp -d)" || tmpdir=""
    if [ -z "$tmpdir" ] || [ ! -d "$tmpdir" ]; then
      stage="preflight"
      detail="could not create a temporary directory"
      break
    fi
    log="$tmpdir/output"
    dispatcher="$tmpdir/$command_name"
    : >"$log"

    {
      printf '%s\n' '#!/bin/sh'
      printf 'exec npx --yes %s "$@"\n' "$package"
    } >"$dispatcher" || rc=$?
    if [ "$rc" -ne 0 ]; then
      stage="install"
      detail="could not write the npx dispatcher (exited $rc)"
      break
    fi
    chmod 0755 "$dispatcher" || rc=$?
    if [ "$rc" -ne 0 ]; then
      stage="install"
      detail="could not make the npx dispatcher executable (chmod exited $rc)"
      break
    fi

    rc=0
    timeout "${max_time}s" "$dispatcher" --version >"$tmpdir/version" 2>"$log" || rc=$?
    if [ "$rc" -ne 0 ]; then
      stage="verify"
      if [ "$rc" -eq 124 ]; then
        detail="npx did not resolve and start $package within ${max_time}s"
      else
        detail="npx resolved $package but '$command_name --version' exited $rc"
      fi
      break
    fi

    rc=0
    mkdir -p "$(dirname "$probe")" || rc=$?
    if [ "$rc" -eq 0 ]; then
      mv -f "$dispatcher" "$probe" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      stage="install"
      detail="could not place the verified dispatcher at $probe (exited $rc)"
      break
    fi

    local version_line=""
    IFS= read -r version_line <"$tmpdir/version" || version_line="(no output)"
    printf 'nixagent: %s: installed and verified %s -- %s\n' "$name" "$probe" "$version_line"
    break
  done

  if [ -n "$stage" ]; then
    local severity="FAILED"
    if [ "$on_failure" = "warn" ]; then
      severity='WARNING (nixagent.home.onInstallFailure = "warn")'
    fi
    {
      printf '\n'
      printf 'nixagent: %s: %s -- npx delivery did not complete\n' "$name" "$severity"
      printf '    stage:     %s\n' "$stage"
      printf '    detail:    %s\n' "$detail"
      printf '    package:   %s (run with npx --yes)\n' "$package"
      printf '    expected:  %s\n' "$probe"
      if [ -n "$log" ] && [ -s "$log" ]; then
        printf '    ---- npx output ----\n'
        sed 's/^/    /' "$log"
        printf '    --------------------\n'
      fi
      printf "    the '%s' command is NOT available for this user.\n" "$command_name"
      printf '\n'
    } >&2

    if [ -n "$tmpdir" ]; then rm -rf "$tmpdir"; fi
    if [ "$on_failure" = "warn" ]; then
      return 0
    fi
    return 1
  fi

  if [ -n "$tmpdir" ]; then rm -rf "$tmpdir"; fi
  return 0
}
