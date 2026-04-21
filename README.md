# kbn-dev-tools

One-command installer for the Kibana dual-mode dev environment. Spins up
**serverless** (`:5601`) and **stateful** (`:5611`) Kibana instances in
parallel with shared ES clusters and optimizer.

## Quick install

```bash
git clone https://github.com/<org>/kbn-dev-tools
cd kbn-dev-tools
./install.sh
```

This installs:
- `kbn-dev` and `kbn-dev-ctl` to `~/.local/bin/`
- Claude Code agent skills to `~/.claude/skills/` and `~/.agents/skills/`
- Scripts + skills into your kibana repo (if found)

## Prerequisites

- **Node version manager** — any of: [nvm](https://github.com/nvm-sh/nvm), [fnm](https://github.com/Schniz/fnm), [volta](https://volta.sh), [mise](https://mise.jdx.dev), or [asdf](https://asdf-vm.com)
- **Docker** — required for ES clusters
- **Kibana repo** — a local checkout (the scripts run from its root)
- **Chrome** — auto-detected, or set `CHROME_BIN` (optional)

## Usage

All commands must be run from the **kibana repo root**:

```bash
cd ~/workplace/kibana    # or wherever your checkout is

kbn-dev                  # start everything (interactive, with tmux logs)
kbn-dev --quiet          # start without tmux viewer
kbn-dev --clean          # wipe caches and rebuild
kbn-dev-ctl status       # health check
kbn-dev-ctl status --json  # machine-readable
kbn-dev-ctl logs kbnsls  # last 50 lines of serverless kibana
kbn-dev-ctl logs all --grep ERROR  # errors everywhere
kbn-dev-ctl attach       # open tmux split-pane log viewer
kbn-dev-ctl restart all  # full restart
kbn-dev-ctl stop         # stop everything
```

## What it starts

| Component     | Port | Description                     |
|---------------|------|---------------------------------|
| ES Serverless | 9200 | Docker-based serverless cluster |
| ES Stateful   | 9201 | Snapshot-based trial cluster    |
| Optimizer     | —    | Shared plugin builder (watch)   |
| Kibana SLS    | 5601 | Serverless Kibana               |
| Kibana Stack  | 5611 | Stateful Kibana                 |

## Login

| Instance   | URL                      | Credentials                |
|------------|--------------------------|----------------------------|
| Serverless | http://localhost:5601    | Select "admin" role (mock) |
| Stateful   | http://localhost:5611    | elastic / changeme         |

## Claude Code / Cursor integration

After install, two agent skills are available:

- **`/kbn-dev`** — Start, stop, restart, view logs, debug failures
- **`/kbn-dev-status`** — Quick status check (lightweight, low token cost)

The skills teach the agent how to manage the dev environment, handle
authentication screens in browser automation, and diagnose failures.

## Environment variables

| Variable                 | Default                                                | Purpose                       |
|--------------------------|--------------------------------------------------------|-------------------------------|
| `KBN_INFERENCE_URL`      | `https://inference.eu-west-1.aws.svc.qa.elastic.cloud` | EIS URL. Set `""` to disable. |
| `KIBANA_EIS_CCM_API_KEY` | (none)                                                 | Skip vault, use key directly. |
| `CHROME_BIN`             | auto-detected                                          | Path to Chrome binary.        |
| `KBN_LOG_DIR`            | `~/.kbn/logs`                                          | Log file directory.           |
| `SKIP_BROWSER_LAUNCH`    | (unset)                                                | Set to skip Chrome launch.    |

## File structure

```
kbn-dev-tools/
├── install.sh              # One-step installer
├── README.md
├── scripts/
│   ├── kbn_dev.sh          # Orchestrator (starts everything)
│   └── kbn_dev_ctl.sh      # Control plane (status/logs/restart/stop)
└── skills/
    ├── kbn-dev/
    │   ├── SKILL.md         # Main agent skill
    │   ├── failure-modes.md # Diagnosis reference (loaded on demand)
    │   └── browser-auth.md  # Auth & browser guidance (loaded on demand)
    └── kbn-dev-status/
        └── SKILL.md         # Lightweight status-only skill
```
