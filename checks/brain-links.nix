# SPDX-License-Identifier: MIT OR Apache-2.0
# RUNS lib/brain.nix against a scratch home and asserts the outcome, because link wiring whose
# idempotency and non-destructiveness are only asserted on paper is wiring nobody can trust.
#
# Covered: every library skill reaches ~/.claude/skills and ~/.agents/skills; tool-owned content
# (Claude's `synced/`, a tool's own skill directory, even one sharing a library skill's name) is
# never touched; instructions are written through a leftover symlink without following it; a
# deleted skill's links are pruned; Codex's duplicate links into the library are removed; a
# second run changes nothing.
{ pkgs }:
let
  brain = import ../lib/brain.nix;
  home = "$TMPDIR/home";
  skills = "$TMPDIR/library";
  wiring = brain.all {
    inherit home skills;
    claudeInstructions = "@~/brain/AGENTS.md";
    claudeMemoryDir = "$TMPDIR/memory/$(uname -n)";
    codexInstructions = "# Shared brain\n\nRead ~/brain/AGENTS.md.";
  };
in
pkgs.runCommand "nixagent-brain-links" { } ''
  set -eu
  mkdir -p ${skills}/alpha ${skills}/beta ${skills}/not-a-skill
  echo alpha > ${skills}/alpha/SKILL.md
  echo beta > ${skills}/beta/SKILL.md
  mkdir -p ${home}/.claude/skills/synced/account ${home}/.agents/skills/tool-owned ${home}/.agents/skills/beta
  echo keep > ${home}/.agents/skills/beta/SKILL.md
  mkdir -p ${home}/.codex/skills/.system ${home}/.claude "$TMPDIR/elsewhere"
  ln -s ${skills}/alpha ${home}/.codex/skills/alpha
  ln -s "$TMPDIR/elsewhere/old.md" ${home}/.claude/CLAUDE.md

  wire() {
  ${wiring}
  }
  wire

  fail() { echo "FAIL: $*" >&2; exit 1; }
  [ "$(readlink ${home}/.claude/skills/alpha)" = ${skills}/alpha ] || fail "claude link alpha"
  [ "$(readlink ${home}/.claude/skills/beta)" = ${skills}/beta ] || fail "claude link beta"
  [ ! -e ${home}/.claude/skills/not-a-skill ] || fail "directory without SKILL.md linked"
  [ "$(readlink ${home}/.agents/skills/alpha)" = ${skills}/alpha ] || fail "agents link alpha"
  [ ! -L ${home}/.agents/skills/beta ] && [ "$(cat ${home}/.agents/skills/beta/SKILL.md)" = keep ] \
    || fail "a real directory sharing a skill's name was replaced"
  [ -d ${home}/.claude/skills/synced/account ] || fail "Claude's synced/ was touched"
  [ -d ${home}/.agents/skills/tool-owned ] || fail "a tool-owned skill was touched"
  [ ! -L ${home}/.claude/CLAUDE.md ] && [ "$(cat ${home}/.claude/CLAUDE.md)" = "@~/brain/AGENTS.md" ] \
    || fail "CLAUDE.md not written as a regular file"
  [ ! -e "$TMPDIR/elsewhere/old.md" ] || fail "CLAUDE.md written through the leftover symlink"
  grep -q "Read ~/brain/AGENTS.md." ${home}/.codex/AGENTS.md || fail "Codex AGENTS.md"
  [ ! -e ${home}/.codex/skills/alpha ] || fail "Codex duplicate link kept"
  [ -d ${home}/.codex/skills/.system ] || fail "Codex's .system was touched"
  [ "$(readlink ${home}/.claude/projects/*/memory)" = "$TMPDIR/memory/$(uname -n)" ] || fail "memory link"

  rm -r ${skills}/alpha
  before=$(find ${home} -printf '%p %l\n' | sort)
  wire
  [ ! -L ${home}/.claude/skills/alpha ] || fail "claude link to a deleted skill not pruned"
  [ ! -L ${home}/.agents/skills/alpha ] || fail "agents link to a deleted skill not pruned"
  wire
  after=$(find ${home} -printf '%p %l\n' | sort)
  [ "$(echo "$before" | grep -v alpha)" = "$(echo "$after" | grep -v alpha)" ] || fail "not idempotent"

  echo ok > $out
''
