# Kibana Controller — Failure Modes

Reference for diagnosing and fixing common kbn-dev startup and runtime failures.

## Startup failures

### All processes die immediately

**Symptom:** `kbn-dev-ctl status` shows everything down, logs are nearly empty.

**Likely cause:** Wrong Node.js version. Agent shells don't load nvm, so
the system node doesn't match kibana's `.nvmrc`.

**Fix:**
```bash
# Source nvm first (required for all yarn commands in agent shells)
source "${NVM_DIR:-$HOME/.nvm}/nvm.sh" --no-use && nvm use --silent
kbn-dev-ctl logs main --grep "incompatible\|Expected version"
# If node mismatch: nvm install $(cat .nvmrc)
```

### ES clusters fail to start

**Symptom:** `essls` or `esstack` shows `"alive": false` within seconds.

**Likely causes:**
1. Docker not running — `docker ps` fails
2. Ports 9200/9300 occupied — OrbStack, another ES instance, etc.
3. Cache corruption — stale `.es/cache` directory
4. Stale kibana-ci containers — `uiam` or ES containers from a previous run

**Fix:**
```bash
docker ps                                    # verify Docker is running
kbn-dev-ctl logs essls --grep "error"   # check specific error
# Restart with clean: kbn-dev --clean
```

### uiam container fails to start (serverless)

**Symptom:** Log shows `Waiting for "uiam" container (unhealthy)` then
`The "uiam" container failed to start within the expected time`.

**Cause:** Stale Docker network or containers from a previous run. The
`elastic` Docker network accumulates stale DNS entries from crashed
containers, causing uiam to fail resolving cosmosdb. `kbn-dev` cleans
containers and the network automatically on startup, and retries up to
3 times.

**Fix if it persists:**
```bash
kbn-dev-ctl stop
docker system prune -a    # nuclear option: clears all Docker state
kbn-dev
```

### Bootstrap fails

**Symptom:** Status stuck at `"state": "starting"`, optimizer never starts.

**Likely causes:**
1. Missing dependencies after branch switch
2. Corrupted node_modules
3. Yarn cache issues

**Fix:**
```bash
kbn-dev-ctl logs main --tail 100       # check bootstrap output
# Clean rebuild:
kbn-dev-ctl stop
yarn kbn clean && yarn kbn bootstrap
kbn-dev --quiet &
```

### Optimizer dies

**Symptom:** `optimizer` shows `"alive": false`, Kibana processes never start.

**Likely cause:** Build errors in plugin code, out-of-memory.

**Fix:**
```bash
kbn-dev-ctl logs optimizer --tail 100
# Usually requires fixing the code error, then:
kbn-dev-ctl stop
kbn-dev --quiet &
```

## Runtime failures

### Kibana crashes after branch switch

**Symptom:** `FATAL: Cannot find module '@kbn/...'`

**Fix:**
```bash
kbn-dev-ctl stop
kbn-dev --quiet --clean &
```

### Port already in use

**Symptom:** `FATAL Error: Port 5601 is already in use`

**Fix:**
```bash
kbn-dev-ctl restart kbnsls   # or kbnstack for port 5611
```

The restart command kills the orphaned process and the monitor loop
restarts Kibana automatically.

### Kibana running but not responding

**Symptom:** Port is open but `curl` times out or returns 503.

**Check:**
```bash
kbn-dev-ctl logs kbnsls --tail 20 --grep "status\|ERROR\|FATAL"
curl -s -o /dev/null -w "%{http_code}" http://localhost:5601/api/status
```

If the status API returns 503, Kibana is still initializing plugins.
Wait and re-check. If it persists, restart.

### EIS / Vault failures

**Symptom:** Vault access fails in non-interactive mode, or `kbn-dev-ccm`
errors in the main log.

**Fix:**
```bash
# Option 1: disable EIS entirely
KBN_INFERENCE_URL="" kbn-dev --quiet &

# Option 2: provide API key directly
export KIBANA_EIS_CCM_API_KEY="your-key-here"
kbn-dev --quiet &

# Option 3: log in to vault first (interactive terminal)
VAULT_ADDR=https://secrets.elastic.co:8200 vault login -method oidc
```

## Log patterns to grep

| Pattern | Meaning |
|---------|---------|
| `succ Serverless ES cluster running` | ES Serverless ready |
| `succ ES cluster is ready` | ES Stateful ready |
| `succ.*bundles compiled successfully` | Optimizer build done |
| `succ all bundles cached` | Optimizer using cache |
| `[INFO ][status] Kibana is now available` | Kibana accepting requests |
| `FATAL` | Unrecoverable error |
| `server crashed` | Kibana process died |
| `Port .* is already in use` | Orphaned process on port |
| `Cannot find module` | Missing dependency (needs bootstrap) |
