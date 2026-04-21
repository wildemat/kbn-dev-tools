---
name: kbn-dev-status
description: >
  Quick status check for the local Kibana dev environment. Use when the
  user asks "is kibana running", "kibana status", "what's the state of
  kibana", "check kibana", "kbn status", "what's kibana doing", or types
  /kbn-dev-status. This is the lightweight skill — for start/stop/restart
  actions, use /kbn-dev instead.
allowed-tools: Bash(kbn-dev-ctl *)
---

# Kibana Status

Run `kbn-dev-ctl status --json` and present a concise summary. Do NOT show raw JSON.

```
!`kbn-dev-ctl status --json 2>/dev/null || echo '{"running": false}'`
```

Format as:

| Component | Status | Ready |
|-----------|--------|-------|
| ES Serverless | up/down | yes/no |
| ES Stateful | up/down | yes/no |
| Optimizer | up/down | — |
| Kibana SLS | up/down | yes/no |
| Kibana Stack | up/down | yes/no |

Add URLs for ready instances:
- Serverless: http://localhost:5601
- Stateful: http://localhost:5611

If not running, say "Kibana is not running. Start with /kbn-dev"
