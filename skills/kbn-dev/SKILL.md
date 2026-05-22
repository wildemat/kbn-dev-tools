---
name: kbn-dev
description: >
  Start, stop, restart, and manage local Kibana dev instances (serverless
  on :5601, stateful on :5611). Use when the user wants to start kibana,
  restart kibana, stop kibana, view logs, or debug startup failures.
  Trigger words: "start kibana", "restart kibana", "stop kibana",
  "kbn-dev", "spin up kibana", "kibana logs", "es logs".
  For status-only queries ("is kibana running", "kibana status"), prefer
  the /kbn-dev-status skill instead.
allowed-tools: >
  Bash(kbn-dev-ctl *)
  Bash(kbn-dev *)
  Bash(curl *)
  Bash(lsof *)
  Bash(kill *)
  Bash(tail *)
  Bash(grep *)
---

# Kibana Dev Environment

Dual-mode Kibana dev launcher: serverless (:5601) + stateful (:5611).

`kbn-dev` starts everything. `kbn-dev-ctl` controls it.
Both scripts detect and activate the correct node version automatically
(supports nvm, fnm, volta, mise, asdf) — no manual setup needed.

**All commands must run from the kibana repo root.** If you're not there,
`cd` to it first. Check with: `grep -q '"name": "kibana"' package.json 2>/dev/null && echo OK || echo "NOT in kibana root"`

## Current status

```
!`kbn-dev-ctl status --json 2>/dev/null || echo '{"running": false, "state": "not_running"}'`
```

## Commands

| Action | Command |
|--------|---------|
| Start | `kbn-dev --quiet` |
| Start clean | `kbn-dev --quiet --clean` |
| Status | `kbn-dev-ctl status --json` |
| Logs | `kbn-dev-ctl logs <component> [--tail N] [--grep PAT]` |
| Restart | `kbn-dev-ctl restart <serverless\|stateful\|all>` |
| Stop | `kbn-dev-ctl stop` |

Components: `essls`, `esstack`, `optimizer`, `kbnsls`, `kbnstack`, `main`, `all`

## Starting Kibana

Check status first. If already running, tell the user. If not:

1. Say: "Spinning up Kibana, standby... (run /kbn-dev-status to check)"
2. Run `kbn-dev --quiet` in background. To pin the stateful ES version, add `--es-version <ver>` using a full patch version like `9.3.3` (script strips a trailing `-SNAPSHOT` if present); only affects stack ES via `yarn es snapshot`, not serverless.
3. Poll silently:
   ```bash
   for i in $(seq 1 40); do
     sleep 15
     kbn_state=$(kbn-dev-ctl status --json 2>/dev/null)
     sls=$(echo "$kbn_state" | grep -c '"kbnsls".*"ready": true')
     stack=$(echo "$kbn_state" | grep -c '"kbnstack".*"ready": true')
     is_running=$(echo "$kbn_state" | grep -c '"running": true')
     if [ "$sls" -gt 0 ] && [ "$stack" -gt 0 ]; then break; fi
     if [ "$is_running" = "0" ] && [ $i -gt 2 ]; then break; fi
   done
   ```
4. Report: both ready → URLs + "Chrome opened for both". Neither → "check logs". One failed → offer restart.

State progression: `starting` → `es_starting` → `optimizer_ready` → `running`.

**Never** show raw JSON or intermediate polls. One message at start, one when done.

## Chrome auto-open

`kbn-dev` opens two Chrome windows with isolated profiles (`kbn-sls`, `kbn-stack`) once each Kibana instance becomes available — works both interactively and when invoked by an agent. Missing profile dirs are auto-created on first run (no prompt in non-interactive mode).

After the poll completes, verify Chrome actually launched:
```bash
pgrep -c -f "user-data-dir=.*kbn-(sls|stack)"
```
Expect both profiles represented (count ≥ 2 — Chrome's main+helper processes usually push this much higher). Also visible in `~/.kbn-dev/logs/main.log` as `Opening Chrome: <url>` lines. If neither shows:
- Check whether `SKIP_BROWSER_LAUNCH` is set, or Chrome isn't on PATH.
- Fall back to telling the user the URLs and to open them manually.
- Do NOT re-launch Chrome from the skill — the script already attempts it; duplicating creates extra windows.

## Updating kbn-dev / skill

The installed `kbn-dev`, `kbn-dev-ctl`, and skill are **copies** placed by `install.sh`. To deploy edits, modify the source in `~/workplace/kbn-dev-tools/` and run:
```bash
cd ~/workplace/kbn-dev-tools && KBN_DEV_INSTALL_MODE=copy ./install.sh
```
Never edit `/Users/wildmat/.local/bin/kbn-dev*` or `/Users/wildmat/.claude/skills/kbn-dev/*` directly — those get clobbered on the next install.

## Viewing logs

**"Open the logs":** Requires interactive terminal. Tell the user:
> Run `kbn-dev-ctl attach` in your terminal.

**Inline logs (what you CAN do):**
```bash
kbn-dev-ctl logs kbnsls --tail 50
kbn-dev-ctl logs all --grep "ERROR|FATAL"
```

Do NOT open terminal tabs, run AppleScript, or `tail -f` manually.

## Failure quick-ref

- **Node mismatch**: install the version in `.nvmrc` (e.g. `nvm install $(cat .nvmrc)` or `fnm install $(cat .nvmrc)`)
- **Port in use**: `kbn-dev-ctl restart all`
- **Docker not running**: start Docker
- **After branch switch**: `kbn-dev --quiet --clean`
- **Vault failed**: `KBN_INFERENCE_URL="" kbn-dev --quiet`

For detailed diagnosis, read [failure-modes.md](failure-modes.md).

## Auth & browser interaction

For login screens, curl auth examples, and browser automation guidance,
read [browser-auth.md](browser-auth.md).

| Instance | URL | Login |
|----------|-----|-------|
| Serverless | http://localhost:5601 | select "admin" role (no password) |
| Stateful | http://localhost:5611 | elastic / changeme |

## Proactive monitoring

After editing `.ts`, `.tsx`, `.yml`, or config files, silently run
`kbn-dev-ctl status --json`. If a component is down, restart and
tell the user briefly: "Kibana SLS crashed, restarting..."
