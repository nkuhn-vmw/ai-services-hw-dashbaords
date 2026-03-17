#!/usr/bin/env bash
#
# configure-billback-mapping.sh
#
# Discovers ALL GenAI service instances on a Cloud Foundry foundation via the
# CF API and patches billback dashboard JSON files with the correct
# label_replace chains and ServiceInstance custom variable.
#
# Patches two dashboards:
#   - ai-services-billback-dashboard.json
#   - ai-services-monthly-billback-report.json
#
# Usage:
#   ./scripts/configure-billback-mapping.sh \
#     --cf-api https://api.sys.tas-cdc.kuhn-labs.com \
#     --cf-user admin \
#     --cf-password <password>
#
# Or with environment variables:
#   CF_API=https://api.sys.tas-cdc.kuhn-labs.com \
#   CF_USER=admin CF_PASSWORD=<password> \
#   ./scripts/configure-billback-mapping.sh
#
# Prerequisites: curl, python3, jq
#
# What it does:
#   1. Authenticates to CF UAA to get an access token
#   2. Lists all service instances of the GenAI service offering
#   3. Resolves each SI's space and organization names
#   4. Strips any existing label_replace chains from dashboard queries
#   5. Adds new label_replace chains (INSIDE sum by() aggregations) for all SIs
#   6. Updates the ServiceInstance custom variable with friendly names
#

set -euo pipefail

# --- Parse arguments / env vars ---
CF_API="${CF_API:-}"
CF_USER="${CF_USER:-}"
CF_PASSWORD="${CF_PASSWORD:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cf-api)    CF_API="$2"; shift 2 ;;
    --cf-user)   CF_USER="$2"; shift 2 ;;
    --cf-password) CF_PASSWORD="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --cf-api <url> --cf-user <user> --cf-password <pass>"
      echo ""
      echo "Discovers GenAI service instances and patches billback dashboards."
      echo ""
      echo "Options:"
      echo "  --cf-api       CF API URL (e.g., https://api.sys.example.com)"
      echo "  --cf-user      CF admin username"
      echo "  --cf-password  CF admin password"
      echo ""
      echo "Environment variables CF_API, CF_USER, CF_PASSWORD also accepted."
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$CF_API" || -z "$CF_USER" || -z "$CF_PASSWORD" ]]; then
  echo "Error: CF_API, CF_USER, and CF_PASSWORD are required."
  echo "Run with --help for usage."
  exit 1
fi

# Derive UAA login URL from CF API URL (api.sys.* -> login.sys.*)
LOGIN_URL=$(echo "$CF_API" | sed 's|//api\.|//login.|')

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

BILLBACK_DASHBOARD="$REPO_DIR/ai-services-billback-dashboard.json"
MONTHLY_REPORT="$REPO_DIR/ai-services-monthly-billback-report.json"

echo "==> CF API: $CF_API"
echo "==> Login:  $LOGIN_URL"

# --- Step 1: Get UAA token ---
echo ""
echo "==> Authenticating to CF..."
TOKEN=$(curl -s -k "$LOGIN_URL/oauth/token" \
  -d "grant_type=password&username=${CF_USER}&password=${CF_PASSWORD}" \
  -d "client_id=cf&client_secret=" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

echo "    Authenticated."

# --- Step 2: Discover GenAI service instances ---
echo ""
echo "==> Discovering GenAI service instances..."

# Find service offerings that look like GenAI / AI Services
# We look for service instances bound to ai-server metrics
# Strategy: query Prometheus for distinct platform_cf_service_instance_guid values,
# then resolve each via CF API. This catches ALL SIs regardless of service offering name.

# But we don't have Prometheus access here. Instead, list all service instances and
# filter by service offering name containing "genai" or "ai-service".
# If that yields nothing, fall back to listing ALL service instances.

INSTANCES_JSON=$(python3 - "$CF_API" "$TOKEN" << 'PYSCRIPT'
import json, sys, urllib.request, ssl

cf_api = sys.argv[1]
token = sys.argv[2]

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def cf_get(path):
    req = urllib.request.Request(
        f"{cf_api}{path}",
        headers={"Authorization": f"Bearer {token}"}
    )
    with urllib.request.urlopen(req, context=ctx) as resp:
        return json.loads(resp.read())

# Get all service offerings to find GenAI ones
offerings = []
page = "/v3/service_offerings?per_page=100"
while page:
    data = cf_get(page)
    for o in data.get("resources", []):
        name = o.get("name", "").lower()
        if "genai" in name or "ai-service" in name or "ai_service" in name or "tanzu-ai" in name:
            offerings.append(o["guid"])
    page = data.get("pagination", {}).get("next", {})
    if page:
        page = page.get("href", "")
        if page:
            page = page.replace(cf_api, "")
        else:
            page = None
    else:
        page = None

# Get service plans for those offerings
plan_guids = set()
for offering_guid in offerings:
    data = cf_get(f"/v3/service_plans?service_offering_guids={offering_guid}&per_page=100")
    for plan in data.get("resources", []):
        plan_guids.add(plan["guid"])

# Get service instances for those plans
instances = []
for plan_guid in plan_guids:
    page = f"/v3/service_instances?service_plan_guids={plan_guid}&per_page=100"
    while page:
        data = cf_get(page)
        for si in data.get("resources", []):
            space_guid = si.get("relationships", {}).get("space", {}).get("data", {}).get("guid", "")
            instances.append({
                "guid": si["guid"],
                "name": si.get("name", "unknown"),
                "space_guid": space_guid
            })
        page = data.get("pagination", {}).get("next", {})
        if page:
            page = page.get("href", "")
            if page:
                page = page.replace(cf_api, "")
            else:
                page = None
        else:
            page = None

# Resolve space and org names
for inst in instances:
    if inst["space_guid"]:
        space = cf_get(f"/v3/spaces/{inst['space_guid']}")
        inst["space_name"] = space.get("name", "unknown")
        org_guid = space.get("relationships", {}).get("organization", {}).get("data", {}).get("guid", "")
        if org_guid:
            org = cf_get(f"/v3/organizations/{org_guid}")
            inst["org_name"] = org.get("name", "unknown")
        else:
            inst["org_name"] = "unknown"
    else:
        inst["space_name"] = "unknown"
        inst["org_name"] = "unknown"

print(json.dumps(instances))
PYSCRIPT
)

NUM_INSTANCES=$(echo "$INSTANCES_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [[ "$NUM_INSTANCES" -eq 0 ]]; then
  echo "    Warning: No GenAI service instances found via CF API."
  echo "    Dashboards will not be patched."
  echo ""
  echo "    If instances exist but use a different service offering name,"
  echo "    check the CF API manually:"
  echo "      cf curl /v3/service_offerings"
  exit 0
fi

echo ""
echo "    Found $NUM_INSTANCES service instance(s):"
echo "$INSTANCES_JSON" | python3 -c "
import json,sys
for si in json.load(sys.stdin):
    print(f\"    {si['guid'][:8]}... -> {si['name']} ({si['org_name']}/{si['space_name']})\")"

# --- Step 3: Patch dashboards ---
echo ""

python3 - "$BILLBACK_DASHBOARD" "$MONTHLY_REPORT" "$INSTANCES_JSON" << 'PYTHON_PATCH'
import json
import sys
import re
import os

billback_path = sys.argv[1]
monthly_path = sys.argv[2]
instances = json.loads(sys.argv[3])


def strip_all_label_replace(expr):
    """Remove ALL label_replace() wrappers from an expression.

    Uses paren-balanced parsing to correctly handle nested calls.
    Removes label_replace calls that set organization_name, space_name,
    or service_instance_name based on platform_cf_service_instance_guid.
    """
    changed = True
    while changed:
        changed = False
        # Look for label_replace( at various positions
        pattern = r'label_replace\('
        for m in list(re.finditer(pattern, expr)):
            start = m.start()
            # Find the matching closing paren
            depth = 0
            pos = m.end() - 1  # position of the opening paren
            for i in range(pos, len(expr)):
                if expr[i] == '(':
                    depth += 1
                elif expr[i] == ')':
                    depth -= 1
                    if depth == 0:
                        end = i + 1
                        break
            else:
                continue

            full_call = expr[start:end]
            # Only strip if it's a GUID-based org/space/si_name mapping
            if 'platform_cf_service_instance_guid' in full_call and any(
                label in full_call for label in [
                    '"organization_name"', '"space_name"', '"service_instance_name"'
                ]
            ):
                # Extract the first argument (inner expression)
                inner_start = m.end()
                # Find the first comma at depth 1 (separates inner expr from label args)
                depth2 = 1
                for j in range(inner_start, end):
                    if expr[j] == '(':
                        depth2 += 1
                    elif expr[j] == ')':
                        depth2 -= 1
                    elif expr[j] == ',' and depth2 == 1:
                        inner_expr = expr[inner_start:j].strip()
                        expr = expr[:start] + inner_expr + expr[end:]
                        changed = True
                        break
                if changed:
                    break

    return expr


def add_label_replace_chain(expr, instances_list):
    """Add label_replace chains for all service instances.

    CRITICAL: label_replace calls must be placed INSIDE sum by() aggregations,
    not outside. When sum by(organization_name, space_name) runs, it drops
    platform_cf_service_instance_guid (not in group-by list), so label_replace
    placed outside cannot match on it.

    Correct:  sum by(org, space) (label_replace(label_replace(increase(...), ...), ...))
    Wrong:    label_replace(sum by(org, space) (increase(...)), ...)
    """
    # First strip any existing GUID-based label_replace chains
    clean = strip_all_label_replace(expr)

    # Build the label_replace chain for all instances
    def wrap_with_lr(inner, inst_list):
        result = inner
        for inst in inst_list:
            guid = inst['guid']
            org = inst['org_name']
            space = inst['space_name']
            name = inst['name']
            result = (
                f'label_replace({result}, '
                f'"organization_name", "{org}", '
                f'"platform_cf_service_instance_guid", "{guid}")'
            )
            result = (
                f'label_replace({result}, '
                f'"space_name", "{space}", '
                f'"platform_cf_service_instance_guid", "{guid}")'
            )
            result = (
                f'label_replace({result}, '
                f'"service_instance_name", "{name}", '
                f'"platform_cf_service_instance_guid", "{guid}")'
            )
        return result

    # Check if there's a sum by() wrapper
    sum_match = re.match(r'^(sum\s+by\s*\([^)]+\)\s*\()(.*)\)$', clean, re.DOTALL)

    if sum_match:
        prefix = sum_match.group(1)  # "sum by(...) ("
        inner = sum_match.group(2)   # everything inside
        return prefix + wrap_with_lr(inner, instances_list) + ")"
    else:
        return wrap_with_lr(clean, instances_list)


def build_service_instance_variable(instances_list):
    """Build the custom ServiceInstance variable query and options."""
    entries = []
    options = [{"selected": True, "text": "All", "value": "$__all"}]

    for inst in instances_list:
        label = f"{inst['name']} [{inst['org_name']}/{inst['space_name']}]"
        entries.append(f"{label} : {inst['guid']}")
        options.append({
            "selected": False,
            "text": label,
            "value": inst['guid']
        })

    query = ",\n".join(entries)
    return query, options


def patch_dashboard(path, instances_list):
    """Patch a single dashboard with SI mappings."""
    if not os.path.exists(path):
        print(f"    Skipping {os.path.basename(path)} (file not found)")
        return

    with open(path, 'r') as f:
        dashboard = json.load(f)

    # 1. Update ServiceInstance custom variable
    var_query, var_options = build_service_instance_variable(instances_list)
    for var in dashboard.get('templating', {}).get('list', []):
        if var.get('name') == 'ServiceInstance':
            var['query'] = var_query
            var['options'] = var_options
            var['current'] = {"selected": True, "text": "All", "value": "$__all"}

    # 2. Patch all panel targets that reference platform_cf_service_instance_guid
    target_count = 0
    for panel in dashboard.get('panels', []):
        for target in panel.get('targets', []):
            expr = target.get('expr', '')
            if not expr:
                continue
            # Patch queries that use service instance guid (billback queries)
            if 'platform_cf_service_instance_guid' in expr:
                target['expr'] = add_label_replace_chain(expr, instances_list)
                target_count += 1

    with open(path, 'w') as f:
        json.dump(dashboard, f, indent=2)
        f.write('\n')

    print(f"==> Patched {os.path.basename(path)}: "
          f"{len(instances_list)} SI mappings, {target_count} queries updated")


# Patch both dashboards
patch_dashboard(billback_path, instances)
patch_dashboard(monthly_path, instances)

PYTHON_PATCH

echo ""
echo "==> Done! Billback dashboards updated with service instance mappings."
echo ""
echo "To deploy to Grafana, import the dashboard JSON files or use the API:"
echo "  curl -s -k -u 'admin:<password>' \\"
echo "    -X POST 'https://grafana.<SYSTEM_DOMAIN>/api/dashboards/db' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"dashboard\": <json>, \"overwrite\": true}'"
