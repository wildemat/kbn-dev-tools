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
2. Run `kbn-dev --quiet` in background.
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
4. Report: both ready → URLs. Neither → "check logs". One failed → offer restart.

State progression: `starting` → `es_starting` → `optimizer_ready` → `running`.

**Never** show raw JSON or intermediate polls. One message at start, one when done.

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
