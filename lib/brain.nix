# SPDX-License-Identifier: MIT OR Apache-2.0
#
# The brain wiring: ONE shared knowledge store (instructions, memory, and above all ONE skill
# library) connected to every agent client that reads it from a home directory.
#
# Each function returns a plain POSIX sh snippet. No store paths and no tools beyond coreutils,
# because the same snippet has two kinds of consumer: the home-manager module
# (modules/brain-home.nix, where `run` is home-manager's dry-run-aware wrapper) and any
# container that runs a vendor image without /nix/store (an agent-orchestration pod, where `run`
# is empty). Text arguments are written verbatim through quoted heredocs; path arguments are
# placed in double quotes, so a caller may use shell expansion such as $(uname -n) in them.
#
# Where each client looks, measured with a probe skill on 2026-09-26: Claude Code reads
# ~/.claude/skills only; Codex, opencode and Grok Build all read the tool-neutral
# ~/.agents/skills from the home. Both folders also hold content the tools install themselves
# (Claude Code's `synced/` subtree of account skills, Orca's own skills), so the library is linked
# in ONE LINK PER SKILL and never as a whole-folder link, which would pour that content into the
# shared library. A real directory that already carries a skill's name is left alone.
rec {
  # Write `text` to `path`, converging from any earlier state. A symlink left at `path` by an
  # older layout would make `install` write through it into its target, so it is removed first.
  writeText = { path, text, tag, run ? "" }: ''
    nixagent_tmp=$(mktemp)
    cat > "$nixagent_tmp" <<'${tag}'
    ${text}
    ${tag}
    if [ -L "${path}" ]; then ${run} rm -f "${path}"; fi
    ${run} install -Dm644 "$nixagent_tmp" "${path}"
    rm -f "$nixagent_tmp"
  '';

  # Link every skill of `skills` (a directory holding <name>/SKILL.md) into `dir`, and prune
  # links into `skills` whose skill has gone. Anything else in `dir` is not touched.
  skillLinks = { dir, skills, run ? "" }: ''
    ${run} mkdir -p "${dir}"
    for skill in "${skills}"/*; do
      [ -f "$skill/SKILL.md" ] || continue
      name=$(basename "$skill")
      if [ -d "${dir}/$name" ] && [ ! -L "${dir}/$name" ]; then continue; fi
      ${run} ln -sfn "$skill" "${dir}/$name"
    done
    for link in "${dir}"/*; do
      [ -L "$link" ] || continue
      case "$(readlink "$link")" in
        "${skills}"/*) [ -e "$link" ] || ${run} rm -f "$link" ;;
      esac
    done
  '';

  # Claude Code: global instructions, the skill library, and optionally a memory directory
  # linked as the auto-memory of sessions started in the home directory itself.
  claude = { home, skills, instructions ? null, memoryDir ? null, run ? "" }:
    let
      # Claude Code names a project's state directory after its path with / turned into -.
      homeProject = builtins.replaceStrings [ "/" ] [ "-" ] home;
    in
    (if memoryDir == null then "" else ''
      ${run} mkdir -p "${home}/.claude/projects/${homeProject}"
      ${run} ln -sfn "${memoryDir}" "${home}/.claude/projects/${homeProject}/memory"
    '')
    + (if instructions == null then "" else
    writeText {
      path = "${home}/.claude/CLAUDE.md";
      text = instructions;
      tag = "NIXAGENT_CLAUDE_MD";
      inherit run;
    })
    + skillLinks { dir = "${home}/.claude/skills"; inherit skills run; };

  # Every client that reads the tool-neutral Agent Skills folder: Codex, opencode, Grok Build.
  agents = { home, skills, run ? "" }:
    skillLinks { dir = "${home}/.agents/skills"; inherit skills run; };

  # Codex: global instructions in $CODEX_HOME/AGENTS.md. Codex takes its skills from
  # ~/.agents/skills, so a link into the library under ~/.codex/skills would load that skill
  # twice; such links are removed. ~/.codex/skills/.system stays Codex's own.
  codex = { home, skills, instructions ? null, run ? "" }:
    (if instructions == null then "" else
    writeText {
      path = "${home}/.codex/AGENTS.md";
      text = instructions;
      tag = "NIXAGENT_AGENTS_MD";
      inherit run;
    })
    + ''
      for link in "${home}/.codex/skills"/*; do
        [ -L "$link" ] || continue
        case "$(readlink "$link")" in
          "${skills}"/*) ${run} rm -f "$link" ;;
        esac
      done
    '';

  # Everything above, for consumers that want the whole wiring in one snippet.
  all = { home, skills, claudeInstructions ? null, claudeMemoryDir ? null, codexInstructions ? null, run ? "" }:
    claude { inherit home skills run; instructions = claudeInstructions; memoryDir = claudeMemoryDir; }
    + agents { inherit home skills run; }
    + codex { inherit home skills run; instructions = codexInstructions; };

  # Only the skill links, cheap enough to re-run every few minutes so a skill created or deleted
  # anywhere reaches every client without waiting for the next activation.
  skillsOnly = { home, skills, run ? "" }:
    skillLinks { dir = "${home}/.claude/skills"; inherit skills run; }
    + agents { inherit home skills run; };
}
