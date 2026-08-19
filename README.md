# Codex Vibe Setup

A portable setup bundle for configuring Codex CLI and the OpenAI/Codex VS Code extension on Windows 11.

## Quick start

Run these commands from the bundle folder, in order:

1. Run `SelfTest-CodexSetup.cmd` to check the bundle before installation.
2. Run `Install-CodexSetup.cmd` on the target Windows 11 machine.
3. Enter provider and MCP credentials when prompted. They are stored in the target user profile, not in this bundle.
4. Run `Verify-CodexSetup.cmd` to confirm the installation.
5. Close and reopen VS Code, then start a new Codex thread.

## What the installer does

- Detects Codex CLI and the OpenAI/Codex VS Code extension independently.
- Asks whether each detected component should be updated.
- Installs reusable skills and plugins from the bundle.
- Preserves unrelated project trust and configuration sections.
- Checks Node.js and npm first. If both already exist, asks whether to update Node.js LTS (`Y`) or skip (`N`); if either is missing, installs Node.js LTS using `winget` or the official Node.js x64 MSI with SHA-256 verification.
- Accepts API-key paste in PowerShell, CMD, Windows Terminal, or Bash. Use the terminal's normal paste shortcut, right-click, `Shift+Insert`, or type `CLIPBOARD` to read the current clipboard.

## Security and privacy

Credentials and personal data are not included in this bundle. The bundle intentionally excludes:

- Authentication files such as `auth.json`
- Sessions and history
- SQLite databases
- Logs
- Project trust paths
- Personal projects
- API keys

Enter credentials only when prompted by the installer. They remain on the target user's profile.
