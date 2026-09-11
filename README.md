# fieldmark-updates

Public deployment artifacts for Fieldmark. Not source code — this repo exists only so a new or
already-deployed Fieldmark instance can install/check for updates without needing any GitHub
credentials (the main source repo is private). Published automatically by the main repo's release
workflow on every tagged release — don't edit anything here by hand.

## Install Fieldmark

**Windows** (PowerShell):
```powershell
irm https://raw.githubusercontent.com/Pancake-Brock/fieldmark-updates/main/install.ps1 | iex
```

**Linux**:
```bash
curl -fsSL https://raw.githubusercontent.com/Pancake-Brock/fieldmark-updates/main/install.sh | bash
```

Both ask whether this is a LAN-only or internet-facing deployment, then handle everything else:
generating secrets, writing `.env`, pulling images, starting the stack, and setting up your first
login (blank or with sample data to explore first). Requires Docker already installed and running
— the installer will tell you if it isn't.

## Files

- `latest.json` — the current version + release notes, checked by every deployed instance's
  Admin > Updates.
- `docker-compose.prod.yml` — the exact file a deployed machine runs; also what the installer
  downloads.
- `install.sh` / `install.ps1` — the installer scripts themselves.
