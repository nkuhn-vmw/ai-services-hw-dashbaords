# AI Services Healthwatch Dashboards

## Project Overview

Grafana dashboards for AI Services on Tanzu Application Service, monitored via Healthwatch 2 / Prometheus. Dashboards are committed to git in their TDC (source-of-truth) state. Deploying to other foundations (e.g., CDC) requires running mapping scripts to patch foundation-specific GUIDs.

## Foundations

- **TDC**: `grafana.sys.tas-tdc.kuhn-labs.com` — source-of-truth dashboards committed to git
- **CDC**: `grafana.sys.tas-cdc.kuhn-labs.com` — deployed from TDC source with foundation-specific patches
- Credentials for both are in `/Users/nkuhn/claude/om-store/`

## Deploying Dashboards to a Non-TDC Foundation

### Critical Rules

1. **Discover ALL service instances** — NEVER assume only one SI exists. Always query the CF API to find every GenAI service instance on the foundation before building label_replace mappings.

2. **label_replace MUST go INSIDE sum by()** — When a query uses `sum by(organization_name, space_name)(...)`, the label_replace calls that create those labels MUST be inside the aggregation. Placing them outside causes `platform_cf_service_instance_guid` to be dropped before label_replace can match on it.
   - CORRECT: `sum by(org, space) (label_replace(label_replace(increase(...), ...), ...))`
   - WRONG: `label_replace(sum by(org, space) (increase(...)), ...)`

3. **Filter gen_ai_token_type!="total"** — The `ai_server_client_token_usage_total` metric has three token types: `input`, `output`, and `total` (where total = input + output). Any query summing tokens must filter `{gen_ai_token_type!="total"}` to avoid double-counting.

### Deployment Steps

```bash
# 1. Patch VM model mapping (queries OpsManager for UUID-to-model mapping)
git checkout -- ai-services-vm-model-health-dashboard.json ai-services-llm-performance-dashboard.json
./scripts/configure-vm-model-mapping.sh -e /path/to/om-env.yml

# 2. Patch billback SI mapping (queries CF API for all service instances)
git checkout -- ai-services-billback-dashboard.json ai-services-monthly-billback-report.json
./scripts/configure-billback-mapping.sh \
  --cf-api https://api.sys.<DOMAIN> \
  --cf-user admin \
  --cf-password <password>

# 3. Manually update Postgres dashboards
#    - ai-services-postgres-health-dashboard.json: Update hidden Instance variable
#    - tanzu-postgres-health-dashboard.json: Update Instance custom variable with foundation's PG instances
#    (Use CF API to discover: cf curl /v3/service_instances?service_plan_names=on-demand-postgres)

# 4. Deploy all dashboards via Grafana API
for f in *.json; do
  python3 -c "
import json,sys
with open('$f') as fh: dash = json.load(fh)
dash.pop('id', None)
print(json.dumps({'dashboard': dash, 'overwrite': True}))
" | curl -s -k -u 'admin:<password>' \
    -X POST 'https://grafana.sys.<DOMAIN>/api/dashboards/db' \
    -H 'Content-Type: application/json' -d @-
done

# 5. Reset local files back to TDC state
git checkout -- *.json
```

### Dashboards Requiring Foundation-Specific Patches

| Dashboard | Script | What Changes |
|-----------|--------|--------------|
| VM Model Health | `configure-vm-model-mapping.sh` | Model dropdown, label_replace legends, value mappings |
| LLM Performance | `configure-vm-model-mapping.sh` | VM panel label_replace, table value mappings |
| Token Usage Billback | `configure-billback-mapping.sh` | ServiceInstance variable, label_replace chains for org/space/name |
| Monthly Token Billback Report | `configure-billback-mapping.sh` | Same as above |
| Postgres Health | Manual | Hidden Instance variable (single deployment GUID) |
| Tanzu Postgres Health | Manual | Instance custom variable (all PG instances) |
| AI Server Health | None | No foundation-specific data |
| LLM Usage Rollup | None | No foundation-specific data |

## Datasource

All dashboards use Prometheus datasource UID `P1809F7CD0C75ACF3` (Healthwatch Prometheus). This is the same on both TDC and CDC.
