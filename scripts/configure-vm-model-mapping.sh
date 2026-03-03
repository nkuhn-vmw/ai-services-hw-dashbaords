#!/usr/bin/env bash
#
# configure-vm-model-mapping.sh
#
# Queries OpsManager to discover the VM-to-model mapping for the GenAI tile,
# then patches the LLM Performance dashboard JSON so VM panels show model names
# instead of BOSH job UUIDs.
#
# Usage:
#   ./scripts/configure-vm-model-mapping.sh -e <om-env-file> [-d <dashboard-json>]
#
# Prerequisites:
#   - om CLI (https://github.com/pivotal-cf/om)
#   - jq
#   - python3 (for JSON patching)
#
# Example:
#   ./scripts/configure-vm-model-mapping.sh -e env.yml
#   ./scripts/configure-vm-model-mapping.sh -e env.yml -d my-dashboard.json

set -euo pipefail

DASHBOARD_FILE="ai-services-llm-performance-dashboard.json"
OM_ENV=""

usage() {
  echo "Usage: $0 -e <om-env-file> [-d <dashboard-json>]"
  echo ""
  echo "Options:"
  echo "  -e  Path to om CLI environment file (required)"
  echo "  -d  Path to dashboard JSON file (default: ${DASHBOARD_FILE})"
  echo ""
  echo "The om env file should contain:"
  echo "  ---"
  echo "  target: https://opsman.example.com"
  echo "  username: admin"
  echo "  password: <password>"
  echo "  skip-ssl-validation: true  # optional"
  exit 1
}

while getopts "e:d:h" opt; do
  case $opt in
    e) OM_ENV="$OPTARG" ;;
    d) DASHBOARD_FILE="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [[ -z "$OM_ENV" ]]; then
  echo "Error: -e <om-env-file> is required"
  usage
fi

if [[ ! -f "$OM_ENV" ]]; then
  echo "Error: om env file not found: $OM_ENV"
  exit 1
fi

# Find the dashboard file (check current dir and repo root)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [[ ! -f "$DASHBOARD_FILE" ]]; then
  if [[ -f "$REPO_DIR/$DASHBOARD_FILE" ]]; then
    DASHBOARD_FILE="$REPO_DIR/$DASHBOARD_FILE"
  else
    echo "Error: Dashboard file not found: $DASHBOARD_FILE"
    echo "Run this script from the repo root or specify -d <path>"
    exit 1
  fi
fi

echo "==> Using om env: $OM_ENV"
echo "==> Dashboard file: $DASHBOARD_FILE"

# Step 1: Find the genai product installation name
echo ""
echo "==> Discovering GenAI tile installation name..."
GENAI_PRODUCT=$(om -e "$OM_ENV" curl -s -p "/api/v0/staged/products" 2>/dev/null \
  | jq -r '.[] | select(.type | startswith("genai")) | .installation_name')

if [[ -z "$GENAI_PRODUCT" ]]; then
  echo "Error: No GenAI tile found in OpsManager staged products."
  echo "Make sure the AI Services tile is installed."
  exit 1
fi

echo "    Found: $GENAI_PRODUCT"

# Step 2: Fetch tile properties
echo "==> Fetching GenAI tile properties..."
PROPS=$(om -e "$OM_ENV" curl -s -p "/api/v0/staged/products/${GENAI_PRODUCT}/properties" 2>/dev/null)

# Step 3: Extract VM-to-model mapping from vllm_models and ollama_models
echo "==> Extracting VM-to-model mapping..."

MAPPING=$(echo "$PROPS" | jq -r '
  [
    (.properties[".errands.vllm_models"].value // [] | .[] |
      {guid: .guid.value, model: .model_name.value, provider: "vllm", vm_type: .vm_type.value}),
    (.properties[".errands.ollama_models"].value // [] | .[] |
      {guid: .guid.value, model: .model_name.value, provider: "ollama", vm_type: .vm_type.value})
  ]
')

NUM_MODELS=$(echo "$MAPPING" | jq length)
if [[ "$NUM_MODELS" -eq 0 ]]; then
  echo "Warning: No models found in tile properties."
  echo "The dashboard will continue to show VM UUIDs."
  exit 0
fi

echo ""
echo "    Found $NUM_MODELS model(s):"
echo "$MAPPING" | jq -r '.[] | "    \(.guid) -> \(.provider)/\(.model) (\(.vm_type))"'

# Step 4: Generate the label_replace chain and value mappings, then patch the dashboard
echo ""
echo "==> Patching dashboard with model name mappings..."

python3 - "$DASHBOARD_FILE" "$MAPPING" << 'PYTHON_SCRIPT'
import json
import sys
import re

dashboard_path = sys.argv[1]
mapping = json.loads(sys.argv[2])

with open(dashboard_path, 'r') as f:
    dashboard = json.load(f)

# Build the label_replace wrapper for a given base expression
def build_label_replace_chain(base_expr, mapping_list):
    """Wrap base_expr in nested label_replace calls to add a 'model_name' label."""
    expr = base_expr
    for entry in mapping_list:
        guid = entry['guid']
        model = entry['model']
        # Escape special regex chars in GUID (hyphens are fine in character class context)
        escaped_guid = guid.replace('-', '\\\\-')
        # Wrap in label_replace - each one checks if exported_job matches the GUID
        expr = (
            f'label_replace({expr}, '
            f'"model_name", "{model}", "exported_job", "{guid}")'
        )
    return expr

# Build value mappings for the table panel
def build_value_mappings(mapping_list):
    """Create Grafana value mappings for exported_job -> model name."""
    options = {}
    for entry in mapping_list:
        options[entry['guid']] = {
            "text": f"{entry['model']} ({entry['provider']})",
            "color": "text"
        }
    return {"type": "value", "options": options}

# VM panel IDs (50-54 are time series, 55 is table)
VM_TIMESERIES_IDS = {50, 51, 52, 53, 54}
VM_TABLE_ID = 55

for panel in dashboard.get('panels', []):
    panel_id = panel.get('id')

    if panel_id in VM_TIMESERIES_IDS:
        # Update each target's expr with label_replace chain
        for target in panel.get('targets', []):
            original_expr = target.get('expr', '')
            wrapped_expr = build_label_replace_chain(original_expr, mapping)
            target['expr'] = wrapped_expr
            # Update legend to use model_name instead of exported_job
            target['legendFormat'] = '{{model_name}} ({{ip}})'

    elif panel_id == VM_TABLE_ID:
        # For the table panel, add value mappings for the exported_job column
        vm_value_mapping = build_value_mappings(mapping)

        # Find the exported_job override and add value mappings
        overrides = panel.get('fieldConfig', {}).get('overrides', [])

        # Check if there's already an exported_job override
        found_ej_override = False
        for override in overrides:
            matcher = override.get('matcher', {})
            if matcher.get('id') == 'byName' and matcher.get('options') == 'exported_job':
                found_ej_override = True
                # Add value mappings property
                override['properties'].append({
                    "id": "mappings",
                    "value": [vm_value_mapping]
                })
                break

        if not found_ej_override:
            # Create new override for exported_job with display name and value mappings
            overrides.append({
                "matcher": {"id": "byName", "options": "exported_job"},
                "properties": [
                    {"id": "displayName", "value": "VM / Model"},
                    {"id": "mappings", "value": [vm_value_mapping]}
                ]
            })

        # Also update the existing "VM Job" override to show "VM / Model"
        for override in overrides:
            matcher = override.get('matcher', {})
            if matcher.get('id') == 'byName' and matcher.get('options') == 'exported_job':
                for prop in override.get('properties', []):
                    if prop.get('id') == 'displayName':
                        prop['value'] = 'VM / Model'

with open(dashboard_path, 'w') as f:
    json.dump(dashboard, f, indent=2)
    f.write('\n')

print(f"    Patched {len(mapping)} model mappings into {dashboard_path}")
PYTHON_SCRIPT

echo ""
echo "==> Done! The dashboard now shows model names on VM panels."
echo ""
echo "To deploy to Grafana:"
echo "  1. Log in to Grafana at https://grafana.<SYSTEM_DOMAIN>"
echo "  2. Navigate to Dashboards > Import"
echo "  3. Paste the contents of $DASHBOARD_FILE"
echo "  4. Click Load, then Import (overwrite existing)"
echo ""
echo "Or deploy via API:"
echo "  curl -sk -X POST https://grafana.<SYSTEM_DOMAIN>/api/dashboards/db \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -u 'admin:<password>' \\"
echo "    -d '{\"dashboard\": <dashboard-json>, \"overwrite\": true}'"
