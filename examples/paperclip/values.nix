# SPDX-License-Identifier: MIT OR Apache-2.0
# Placeholder values the render check evaluates nixagent.paperclip against. Nothing here is a
# real deployment: every path, id and name is illustrative.
{
  nixidy.target.repository = "https://example.org/gitops.git";
  nixidy.target.branch = "main";

  nixagent.paperclip = {
    enable = true;
    namespace = "agents";
    image = "ghcr.io/paperclipai/paperclip@sha256:0000000000000000000000000000000000000000000000000000000000000000";
    host = "paperclip.example.org";
    runAsUser = 1000;
    runAsGroup = 1000;
    home.hostPath = "/srv/paperclip";
    nix.hostPath = "/srv/paperclip-nix";
    brain = {
      root = "/home/alice/brain";
      hostPath = "/srv/brain";
      skills = "/home/alice/brain/skills";
      skillsHostPath = "/srv/brain/skills";
      claudeInstructions = "@~/agents/AGENTS.md";
      claudeMemoryDir = "/home/alice/brain/memory/$(uname -n)";
      codexInstructions = "Read /home/alice/brain/AGENTS.md first.";
    };
    claudeSettings = { includeCoAuthoredBy = false; };
    opencodeConfig = { model = "opencode-go/example-model"; };
    gitconfig = "[user]\n  name = Alice\n";
    clis.grokVersion = "1.0.0";
    secretEnvFrom = [ "paperclip-secrets" ];
    reconciler = {
      boardSecret.name = "paperclip-board";
      attention = { company = "engineering"; commitAgent = "lead"; };
      secretEnv.EXAMPLE_GITHUB_TOKEN = { name = "paperclip-board"; key = "GITHUB_TOKEN"; };
    };
    # A company without an id is created by the reconciler under its prefix, then renamed.
    companies.office = { name = "Example Office"; issuePrefix = "OFF"; };
    companies.engineering = {
      id = "00000000-0000-0000-0000-000000000001";
      name = "Example Engineering";
      issuePrefix = "ENG";
      agents.lead = {
        name = "Lead";
        adapterType = "claude_local";
        adapterConfig = { engine = "cli"; dangerouslySkipPermissions = true; };
        instructions = "You lead Example Engineering.";
      };
      agents.engineer = {
        name = "Engineer";
        role = "engineer";
        reportsTo = "lead";
        adapterType = "opencode_local";
        adapterConfig.model = "opencode-go/example-model";
        instructions = "You implement issues assigned to you.";
      };
      secrets.GH_TOKEN = { env = "EXAMPLE_GITHUB_TOKEN"; description = "Clones private repositories."; };
      connections.github = {
        name = "GitHub";
        gallery = "github";
        method = "mcp-key";
        credentialEnv = "EXAMPLE_GITHUB_TOKEN";
      };
    };
  };
}
