# EIS / CCM Reference

This document explains how `kbn-dev` and `kbn-dev-ccm` handle the Elastic Inference
Service (EIS) and Cloud-Connected Mode (CCM) across serverless and stateful clusters.

---

## Background

EIS provides hosted inference endpoints (embeddings, rerank, completion) backed by
Elastic's cloud infrastructure. To use EIS from a local cluster you must configure
CCM — a trust relationship between the local ES cluster and the cloud, established
by pushing a CCM API key to ES via `PUT /_inference/_ccm`.

There are two kinds of CCM key:

| Key prefix  | Source                       | Notes                                              |
| ----------- | ---------------------------- | -------------------------------------------------- |
| `essu_qa_…` | Vault (`kibana-eis-ccm`)     | Points to the QA inference endpoint; for dev only  |
| `essu_…`    | Elastic Cloud portal (prod)  | Points to your own cloud org's inference endpoint  |

The QA path requires ES to be started with `-E xpack.inference.elastic.url=<QA_URL>`.
The prod path configures the inference URL through the Cloud API or Kibana, so no
extra ES flags are needed.

---

## How `kbn-dev` handles EIS automatically

`kbn-dev` follows this sequence on startup:

```
1. Pre-flight: check vault access (or skip if KIBANA_EIS_CCM_API_KEY is set)
2. Start ES clusters (both serverless and stateful) in parallel
   ↳ ES is started with -E xpack.inference.elastic.url=<KBN_DEV_INFERENCE_URL>
     (only when KIBANA_EIS_CCM_API_KEY is not set — a user-supplied prod key uses
      its own cloud endpoint so the QA URL would conflict)
3. When each ES cluster signals ready:
   ↳ Wait for ES HTTP endpoint
   ↳ Run: CCM_API_KEY=<KIBANA_EIS_CCM_API_KEY> kbn-dev-ccm --sls|--stack
   ↳ Retry up to 3 times on failure
4. Start Kibana (with or without EIS — Kibana still starts if EIS failed)
```

This happens independently for the serverless (port 9200) and stateful (port 9201)
pipelines, so EIS is configured on both clusters before their respective Kibana
instances start.

All EIS logic is consolidated in `kbn-dev-ccm`. `kbn-dev` passes `KIBANA_EIS_CCM_API_KEY`
as `CCM_API_KEY` and the matching `--sls` / `--stack` target; `kbn-dev-ccm` handles
the QA vs prod distinction, vault fetching, and the Cloud API step for prod keys.

### Key resolution at startup

```
KBN_DEV_INFERENCE_URL=""  ──────────────────────────────►  EIS disabled entirely
                                                            (no vault check, no kbn-dev-ccm)

KIBANA_EIS_CCM_API_KEY set  ────────────────────────────►  Forwarded to kbn-dev-ccm as
                                                            CCM_API_KEY (vault skipped)
                                                            essu_qa_… → QA path
                                                            essu_…    → prod path

Neither set  ───────────────────────────────────────────►  QA path via Vault
                                                            (pre-flight vault check,
                                                             -E inference URL on ES,
                                                             kbn-dev-ccm fetches key)
```

### Vault pre-flight

When using the default QA path, `kbn-dev` verifies vault access before starting
anything. In interactive mode it loops, prompting you to log in, until vault
succeeds or you Ctrl+C. In non-interactive mode (CI, agent invocation) it falls
back to starting without EIS.

```bash
# Log in if vault returns a permission error
VAULT_ADDR=https://secrets.elastic.co:8200 vault login --method oidc
```

---

## kbn-dev-ccm — manual EIS setup

`kbn-dev-ccm` (the installed form of `kbn-dev-ccm`) is the script used internally
by `kbn-dev` and is also available directly for pushing CCM keys to a running cluster.
Use it to re-configure EIS on an already-running cluster.

### Decision matrix

```
CCM_NO_EIS=1                 ──────────────────────────►  Exit (nothing to do)

CCM_API_KEY=essu_qa_…        ──────────────────────────►  QA path
CCM_API_KEY=essu_…           ──────────────────────────►  Prod path
CCM_API_KEY unset            ──────────────────────────►  Auto-fetch from Vault → QA path
```

```
         CCM_API_KEY set?
              │
      ┌───────┴───────┐
     Yes              No
      │                │
  key prefix?    CCM_NO_EIS=1?
   essu_qa_…   ──────┤Yes──► exit
   essu_…      │     └No───► fetch from Vault
      │         │                  │
      ▼         ▼                  ▼
   Prod path   (see below)     QA path
      │
  ┌───┴───┐
--stack  --sls
  │        │
  ▼        ▼
Kibana   Cloud API
Cloud    + direct
Connect  ES push
```

### QA path (both --stack and --sls)

The QA path is identical for both targets:

1. Verify ES is reachable
2. Check `xpack.inference.elastic.url` is configured on ES — warn and exit if not
   (ES must be started with `-E xpack.inference.elastic.url=<QA_URL>`)
3. Check `GET /_inference/_ccm` — skip if CCM is already enabled
4. `PUT /_inference/_ccm` with the QA key
5. Verify

Default QA inference URL: `https://inference.eu-west-1.aws.svc.qa.elastic.cloud`

### Prod path — stateful (--stack)

Uses Kibana's internal Cloud Connect API so Kibana handles the full authentication
flow rather than hitting the Cloud API directly:

1. Auto-detect Kibana base path from redirect response
2. `DELETE /internal/cloud_connect/cluster` — disconnect any existing cluster
3. `POST /internal/cloud_connect/authenticate` with the prod key
4. `PUT /internal/cloud_connect/cluster_details` — enable EIS service
5. `GET /_inference/_ccm` — verify

Kibana must be running at `http://localhost:<KBN_PORT>` (default `5611`).

### Prod path — serverless (--sls)

Goes directly through the Elastic Cloud API because the serverless local cluster
doesn't run a Kibana that has Cloud Connect enabled:

1. Gather cluster info from ES (`cluster_uuid`, `cluster_name`, version, license uid)
2. `POST /cloud-connected/clusters?create_api_key=true` — onboard cluster, receive
   a cluster-scoped `keys.eis` key
3. If EIS was already enabled, disable it first to force a fresh key
4. `PATCH /cloud-connected/clusters/{id}` — enable EIS (with retries)
5. `PUT /_inference/_ccm` — push the returned `keys.eis` to local ES
6. `GET /_inference/_ccm` — verify

---

## Environment variables

### kbn-dev

| Variable                 | Default                                                | Effect                                                    |
| ------------------------ | ------------------------------------------------------ | --------------------------------------------------------- |
| `KBN_DEV_INFERENCE_URL`  | `https://inference.eu-west-1.aws.svc.qa.elastic.cloud` | QA inference URL passed to ES via `-E`. Set `""` to disable EIS entirely. |
| `KIBANA_EIS_CCM_API_KEY` | (none)                                                 | Forwarded to `kbn-dev-ccm` as `CCM_API_KEY`. Skips vault. Key prefix (`essu_qa_…` vs `essu_…`) determines QA vs prod path. A prod key also suppresses the `-E` inference URL flag on ES startup. |

### kbn-dev-ccm

| Variable      | Default                              | Effect                                                       |
| ------------- | ------------------------------------ | ------------------------------------------------------------ |
| `CCM_API_KEY` | (none — auto-fetch from Vault)       | The CCM key to use. Prefix determines QA vs prod path.       |
| `CCM_NO_EIS`  | (unset)                              | Set to `1` to exit immediately without configuring EIS.      |
| `ES_PORT`     | `9201` (stack) / `9200` (sls)        | Override the ES port.                                        |
| `KBN_PORT`    | `5611`                               | Override the Kibana port (prod stack path only).             |
| `VAULT_ADDR`  | `https://secrets.elastic.co:8200`    | Override the Vault address.                                  |

> **Note:** `kbn-dev` uses `KIBANA_EIS_CCM_API_KEY` (the standard Kibana env var name)
> and bridges it to `CCM_API_KEY` when invoking `kbn-dev-ccm`. When running `kbn-dev-ccm`
> directly, use `CCM_API_KEY`.

---

## Default ports

| Target    | ES port | Kibana port | ES credentials             |
| --------- | ------- | ----------- | -------------------------- |
| `--stack` | 9201    | 5611        | `elastic:changeme`         |
| `--sls`   | 9200    | N/A         | `elastic_serverless:changeme` |

---

## Common usage

```bash
# kbn-dev — default (vault, QA key, both clusters)
kbn-dev

# kbn-dev — use your own CCM key (no vault)
KIBANA_EIS_CCM_API_KEY=essu_qa_... kbn-dev

# kbn-dev — disable EIS entirely
KBN_DEV_INFERENCE_URL="" kbn-dev

# kbn-dev-ccm — re-push QA key (auto-fetch from vault) to running serverless cluster
kbn-dev-ccm --sls

# kbn-dev-ccm — re-push QA key to running stateful cluster
kbn-dev-ccm --stack

# kbn-dev-ccm — use explicit QA key (no vault needed)
CCM_API_KEY=essu_qa_... kbn-dev-ccm --sls

# kbn-dev-ccm — prod key, stateful (goes through Kibana Cloud Connect)
CCM_API_KEY=essu_... kbn-dev-ccm --stack

# kbn-dev-ccm — prod key, serverless (goes through Cloud API directly)
CCM_API_KEY=essu_... kbn-dev-ccm --sls

# kbn-dev-ccm — skip EIS entirely (no-op, useful for scripting)
CCM_NO_EIS=1 kbn-dev-ccm --stack
```

---

## Troubleshooting

**`vault` not found / access denied**
```bash
VAULT_ADDR=https://secrets.elastic.co:8200 vault login --method oidc
```
Or bypass vault entirely by setting `KIBANA_EIS_CCM_API_KEY`.

**`xpack.inference.elastic.url` not configured on ES**
QA keys require ES to have the inference URL set. `kbn-dev` does this automatically
via the `-E` flag. With `kbn-dev-ccm`, ensure ES was started with:
```bash
-E xpack.inference.elastic.url=https://inference.eu-west-1.aws.svc.qa.elastic.cloud
```

**EIS setup failed after 3 attempts — Kibana still started**
Check `~/.kbn-dev/logs/main.log` for the `kbn-dev-ccm` error output. Kibana starts
regardless so you can debug while it's running:
```bash
kbn-dev-ctl logs main --grep EIS
```

**CCM already enabled — `kbn-dev-ccm` exits early**
This is intentional. To force a re-push, the current CCM state must be cleared.
For the prod serverless path, the script handles this automatically by
disabling and re-enabling EIS on the Cloud API side.

**Prod stack path: `Authentication failed`**
Kibana must be running and the prod key must belong to the correct org. Verify
Kibana is up at `http://localhost:5611` before running `kbn-dev-ccm --stack`.
