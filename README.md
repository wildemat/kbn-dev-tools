# kbn-dev-tools

One-command installer for the Kibana dual-mode dev environment. Spins up
**serverless** (`:5601`) and **stateful** (`:5611`) Kibana instances in
parallel with shared optimizer and EIS via cloud connected mode.

> **Not what you're looking for?** If you just want to try Elasticsearch and Kibana locally without a source checkout, use [elastic/start-local](https://github.com/elastic/start-local) — a one-liner that pulls released Docker images with no repo required.
>
> This repo is for **Kibana developers** who need to run both Kibana modes simultaneously from source, with an optimizer, vault-backed EIS, and Claude Code agent skills for dev workflow automation.

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/wildemat/kbn-dev-tools/main/install.sh | bash
```

Or clone and run locally:

```bash
git clone https://github.com/wildemat/kbn-dev-tools
cd kbn-dev-tools
./install.sh
```

This installs:

- `kbn-dev` and `kbn-dev-ctl` to `~/.local/bin/`
- Claude Code agent skills to `~/.claude/skills/` (and `~/.agents/skills/` if that directory already exists)

## Prerequisites

- **Docker** — required for ES clusters
- **Node version manager** *(optional)* — any of: [nvm](https://github.com/nvm-sh/nvm), [fnm](https://github.com/Schniz/fnm), [volta](https://volta.sh), [mise](https://mise.jdx.dev), or [asdf](https://asdf-vm.com). If detected, kbn-dev will auto-switch to kibana's required Node version. Without one, you must ensure the correct Node version is active yourself.
- **Kibana repo** — a local checkout; run all commands from its root
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

| Component     | Port | Description                                              |
| ------------- | ---- | -------------------------------------------------------- |
| ES Serverless | 9200 | Docker-based serverless cluster                          |
| ES Stateful   | 9201 | Snapshot-based trial cluster                             |
| EIS           | —    | Elastic Inference Service (cloud-connected mode via CCM) |
| Optimizer     | —    | Shared plugin builder (watch, rspack by default)         |
| Kibana SLS    | 5601 | Serverless Kibana                                        |
| Kibana Stack  | 5611 | Stateful Kibana                                          |

EIS runs automatically after each ES cluster is ready — it fetches a QA API key from Vault and pushes it to ES via `node scripts/eis.js`. See [Configuring EIS](#configuring-eis) to change this behaviour.

## Claude Code / Cursor integration

After install, two agent skills are available:

- **`/kbn-dev`** — Start, stop, restart, view logs, debug failures
- **`/kbn-dev-status`** — Quick status check (lightweight, low token cost)

The skills teach the agent how to manage the dev environment, handle
authentication screens in browser automation, and diagnose failures.

## Configuration

The installer creates `~/.kbn-dev/.env` from the `.env.dev` template. Edit it to override defaults — it's sourced automatically by `kbn-dev` on startup. See `.env.dev` for all available variables with inline documentation.

**Resolution order** (`kbn-dev` picks the first that exists):

1. `$KBN_DEV_ENV_FILE` if set (explicit override)
2. `<repo>/.env` if the running executable resolves into a kbn-dev-tools checkout
3. `~/.kbn-dev/.env` (installed default)

**Developing against the repo:** running `./install.sh` from a local clone installs `~/.local/bin/kbn-dev` as a **symlink** into the checkout, so:

- Edits to `scripts/kbn_dev.sh` are picked up live (no reinstall)
- A `.env` in the repo root is picked up automatically (it shadows `~/.kbn-dev/.env` because the symlink resolves into the `scripts/` layout)

Installs via `curl | sh` always **copy** the scripts (the bootstrap tmpdir disappears after install). Force a copy from a local checkout with `KBN_DEV_INSTALL_MODE=copy ./install.sh`.

## Environment variables

All kbn-dev-specific variables use the `KBN_DEV_` prefix to avoid collisions with Kibana or Elasticsearch env vars.

| Variable                        | Default                                                | Purpose                                                      |
| ------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------ |
| `KBN_DEV_INFERENCE_URL`         | `https://inference.eu-west-1.aws.svc.qa.elastic.cloud` | EIS URL passed to ES. Set `""` to disable EIS entirely.      |
| `KBN_DEV_LOG_DIR`               | `~/.kbn-dev/logs`                                      | Log file directory.                                          |
| `KBN_DEV_ES_SLS_PORT`           | `9200`                                                 | Serverless ES HTTP port (transport = port + 100).            |
| `KBN_DEV_ES_SLS_PROJECT_TYPE`   | `elasticsearch_general_purpose`                        | Serverless project type (`elasticsearch_general_purpose`, `observability`, `security`). |
| `KBN_DEV_ES_SLS_EXTRA_ARGS`     | (none)                                                 | Additional args passed to `yarn es serverless`.              |
| `KBN_DEV_ES_STACK_PORT`         | `9201`                                                 | Stateful ES HTTP port (transport = port + 100).              |
| `KBN_DEV_ES_STACK_LICENSE`      | `trial`                                                | Stateful ES license (`basic` or `trial`).                    |
| `KBN_DEV_ES_STACK_ML_ENABLED`   | `false`                                                | Enable ML on stateful ES (memory-heavy).                     |
| `KBN_DEV_ES_STACK_EXTRA_ARGS`   | (none)                                                 | Additional args passed to `yarn es snapshot`.                |
| `KIBANA_EIS_CCM_API_KEY`        | (none)                                                 | Use this EIS/CCM key directly — skips vault lookup and suppresses the `-E xpack.inference.elastic.url` flag on ES startup (prod keys use ES's built-in endpoint). |
| `KBN_USE_RSPACK`                | `true`                                                 | Use rspack optimizer. Set `false` to use legacy webpack.     |
| `CHROME_BIN`                    | auto-detected                                          | Path to Chrome binary.                                       |
| `SKIP_BROWSER_LAUNCH`           | (unset)                                                | Set to any value to skip Chrome launch.                      |

## File structure

```
kbn-dev-tools/
├── install.sh              # One-step installer
├── README.md
├── .env.dev                # Default env var template (copied to ~/.kbn-dev/.env on install)
├── .env                    # Optional repo-local overrides for development (gitignored)
├── set_ccm.sh              # Manual EIS/CCM setup helper (QA + prod, stack + serverless)
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

## Configuring EIS

EIS (Elastic Inference Service) runs automatically in **cloud-connected mode (CCM)**. After each ES cluster is ready, `kbn-dev` calls `node scripts/eis.js` in the Kibana repo to push a CCM key to ES so the inference endpoints work out of the box.

**Default behaviour — vault (QA key):**

No configuration needed. `kbn-dev` checks vault access upfront and prompts you to log in if your token has expired:

```bash
VAULT_ADDR=https://secrets.elastic.co:8200 vault login --method oidc
```

**Skip vault — use your own key:**

Set `KIBANA_EIS_CCM_API_KEY` in `~/.kbn-dev/.env` to any valid CCM key. Vault is skipped entirely:

```bash
KIBANA_EIS_CCM_API_KEY=essu_...  # QA key (essu_qa_…) or prod key
```

**Disable EIS:**

```bash
KBN_DEV_INFERENCE_URL=""
```

**Manual EIS setup with `set_ccm.sh`:**

`set_ccm.sh` is a standalone helper for pushing CCM keys outside of `kbn-dev` — useful when you need to re-configure EIS on a running cluster or use a prod key:

```bash
# Auto-fetch QA key from vault (serverless)
./set_ccm.sh --sls

# Auto-fetch QA key from vault (stateful)
./set_ccm.sh --stack

# Use your own key (prod or QA)
CCM_API_KEY=essu_... ./set_ccm.sh --stack
CCM_API_KEY=essu_qa_... ./set_ccm.sh --sls

# Skip EIS entirely
CCM_NO_EIS=1 ./set_ccm.sh --stack
```

The script detects whether the key is QA or prod from the `essu_qa_` prefix and takes the appropriate path (QA: direct `_inference/_ccm` PUT; prod: Cloud API onboarding then key push).
