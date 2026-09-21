# SPDX-License-Identifier: MIT OR Apache-2.0
# The only check in this repo that RUNS something rather than asserting about it.
#
# ./agents-eval.nix and ./home-eval.nix prove that the catalogue resolves and that the right call
# is rendered. Neither can prove the thing that actually matters about a delivery mode: that it
# does not re-download on a machine that already has the tool, and that every way an install can
# go wrong ends up in front of the operator instead of in a green switch. Those are properties of
# a running shell, so this builds a sandbox with a stubbed `curl` and runs ../lib/install-upstream.sh
# for real against it -- the same file ../modules/home.nix inlines, not a copy.
#
# It also shellchecks that file. It is inlined verbatim into a home-manager activation script on
# every host that selects this plane, which makes a quoting bug in it a broken switch rather than a
# lint finding.
#
# NOTE ON `--no-build`: `nix flake check --no-build` evaluates this and stops, which proves only
# that the derivation is well-formed. The behaviour above is exercised by a plain `nix flake check`.
{ pkgs, lib ? pkgs.lib }:

pkgs.runCommand "nixagent-upstream-install-check"
{
  nativeBuildInputs = with pkgs; [ bash coreutils gnused gnugrep shellcheck ];

  # The two files under test, copied into the store so the derivation is rebuilt whenever either
  # changes -- the harness reads the library at runtime, which no dependency scan would notice.
  installLib = ../lib/install-upstream.sh;
  harness = ./upstream-install.sh;
} ''
  set -eu

  echo "== shellcheck: lib/install-upstream.sh is inlined into a real activation script =="
  shellcheck --shell=bash "$installLib"
  shellcheck --shell=bash "$harness"

  echo
  echo "== behaviour: running the real function against a stubbed network =="
  work="$(mktemp -d)"
  bash "$harness" "$installLib" "$work"

  touch $out
''
