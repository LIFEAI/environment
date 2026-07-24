# Release — LIFEAI Environment Harness

## Repo
- **GitHub:** `LIFEAI/environment`
- **Default branch:** `main`
- **Local path:** `$LIFEAI_ENV` (default `C:/Dev/lifeai-env`)

## Release process

```bash
# 1. Commit changes on main
git add -A && git commit -m "feat/fix: <description>"

# 2. Bump version in manifest.json
# Edit manifest.json version field
git add manifest.json && git commit -m "release: v<version>"

# 3. Tag + push
git tag "v<version>"
git push origin main --tags

# 4. Consuming projects pull on next session start
# The startup guard (Ensure-EnvironmentRepo) auto-fetches and warns if behind.
# Agents or users run: git -C $LIFEAI_ENV pull
```

## No npm publish

This repo is consumed via `git clone` + `$LIFEAI_ENV`, not via npm.
The startup guard checks freshness every session. Provisioning is via
`provision.ps1`.

## Environment targets
- **Local:** `git clone` to `$LIFEAI_ENV`; `provision.ps1` for setup/repair
- **New machine:** `git clone` + `provision.ps1 -Force`
- **Production:** N/A (machine-local tooling, not deployed)

## Version policy
- patch: script fix, config update, hook fix
- minor: new directory, new skill support, new MCP config
- major: breaking provisioner change, directory restructure
