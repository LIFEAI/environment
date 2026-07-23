# LIFEAI Environment Harness

Project-agnostic framework for machine provisioning, service management, session orchestration, and environment audit.

## Quick Start

```powershell
git clone https://github.com/LIFEAI/environment.git C:/Dev/lifeai-env
cd C:/Dev/lifeai-env
./machines/install.ps1     # idempotent — safe to re-run
./audit/audit.ps1           # check installed vs required versions
```

## Structure

```
machines/        Machine provisioning (one-time setup, tool installation)
services/        Daemon lifecycle (restart-clauth, restart-dev-center)
sessions/        Agent session orchestration (cell-init, codevelop, cockpit)
pool/            Worktree pool engine (warm pool, lock-claiming, cleanup)
guards/          Session gatekeepers (startup guard, cleanup)
sync/            Corpus + environment synchronization
editors/         Installable editor/tool configs (pick your editor)
  vscode/        VS Code settings, keybindings, extensions, tasks
  codex/         Codex config
  powershell/    PowerShell profile
terminals/       Installable terminal packages (pick your emulator)
  wezterm/       WezTerm config, launch scripts, cell menus
  windows-terminal/  Windows Terminal settings, profiles, keybindings
platform/        External service infrastructure
  coolify/       Coolify snapshots, server topology
  docker/        Docker compose (Camunda, Flowable, GitHub runner)
  backup/        Supabase backup, data management
contracts/       Tool version requirement schemas
audit/           Drift detection + health-check runners
templates/       Conventions the harness enforces (RELEASE.md)
```

## How It Works

1. **The harness** provides machine setup, service management, and audit tools.
2. **The consuming project** provides an `environment.lock.json` at its root declaring required tool versions.
3. **The startup guard** reads the lock file every session and fails if requirements are unmet.
4. **The audit script** compares installed versions against the lock file and reports drift.

## Multi-Project Support

`projects.json` maps project names to local paths:

```json
{
  "regen-root": "C:/Dev/regen-root",
  "clauth": "C:/Dev/clauth"
}
```

Scripts resolve `$PROJECT_ROOT` from this map or from the `PROJECT_ROOT` environment variable.

## Versioning

This repo is semver-tagged. Consuming projects pin `min_version` in their `environment.lock.json`.
A version bump here does not break consumers until they update their lock file.

## Audit Cadence

- **Every session start:** startup guard checks lock file requirements
- **Weekly:** `audit.ps1` drift detection (automated or manual)
- **Quarterly:** manual review of provisioning scripts (git log is the audit trail)
