#!/usr/bin/env bash
#
# configure-vm-model-mapping.sh
#
# Queries OpsManager to discover the VM-to-model mapping for the GenAI tile,
# then patches dashboard JSON files so VM panels show model names instead of
# BOSH job UUIDs.
#
# Patches two dashboards:
#   - ai-services-vm-model-health-dashboard.json: Populates the Model dropdown
#     with model names (value = VM UUID), adds label_replace for legends, and
#     value mappings on the table.
#   - ai-services-llm-performance-dashboard.json: Adds label_replace chains to
#     any remaining VM panels and value mappings to the table.
#
# Usage:
#   ./scripts/configure-vm-model-mapping.sh -e <om-env-file>
#
# Prerequisites:
#   - om CLI (https://github.com/pivotal-cf/om)
#   - jq
#   - python3
#
# Example:
#   ./scripts/configure-vm-model-mapping.sh -e env.yml

set -euo pipefail

OM_ENV=""

usage() {
  echo "Usage: $0 -e <om-env-file>"
  echo ""
  echo "Options:"
  echo "  -e  Path to om CLI environment file (required)"
  echo ""
  echo "The om env file should contain:"
  echo "  ---"
  echo "  target: https://opsman.example.com"
  echo "  username: admin"
  echo "  password: <password>"
  echo "  skip-ssl-validation: true  # optional"
  exit 1
}

while getopts "e:h" opt; do
  case $opt in
    e) OM_ENV="$OPTARG" ;;
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

# Find the repo root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

VM_HEALTH_DASHBOARD="$REPO_DIR/ai-services-vm-model-health-dashboard.json"
LLM_PERF_DASHBOARD="$REPO_DIR/ai-services-llm-performance-dashboard.json"

echo "==> Using om env: $OM_ENV"

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
  echo "Dashboards will continue to show VM UUIDs."
  exit 0
fi

echo ""
echo "    Found $NUM_MODELS model(s):"
echo "$MAPPING" | jq -r '.[] | "    \(.guid) -> \(.provider)/\(.model) (\(.vm_type))"'

# Step 4: Patch dashboards
echo ""

python3 - "$VM_HEALTH_DASHBOARD" "$LLM_PERF_DASHBOARD" "$MAPPING" << 'PYTHON_SCRIPT'
import json
import sys
import os

vm_health_path = sys.argv[1]
llm_perf_path = sys.argv[2]
mapping = json.loads(sys.argv[3])


def build_label_replace_chain(base_expr, mapping_list):
    """Wrap base_expr in nested label_replace calls to add a 'model_name' label."""
    expr = base_expr
    for entry in mapping_list:
        guid = entry['guid']
        model = entry['model']
        expr = (
            f'label_replace({expr}, '
            f'"model_name", "{model}", "exported_job", "{guid}")'
        )
    return expr


def build_value_mappings(mapping_list):
    """Create Grafana value mappings for exported_job -> model name."""
    options = {}
    for entry in mapping_list:
        options[entry['guid']] = {
            "text": f"{entry['model']} ({entry['provider']})",
            "color": "text"
        }
    return {"type": "value", "options": options}


def add_table_value_mappings(panel, mapping_list):
    """Add value mappings and update display name for exported_job in a table panel."""
    vm_value_mapping = build_value_mappings(mapping_list)
    overrides = panel.get('fieldConfig', {}).get('overrides', [])

    found = False
    for override in overrides:
        matcher = override.get('matcher', {})
        if matcher.get('id') == 'byName' and matcher.get('options') == 'exported_job':
            found = True
            override['properties'].append({
                "id": "mappings",
                "value": [vm_value_mapping]
            })
            for prop in override.get('properties', []):
                if prop.get('id') == 'displayName':
                    prop['value'] = 'VM / Model'
            break

    if not found:
        overrides.append({
            "matcher": {"id": "byName", "options": "exported_job"},
            "properties": [
                {"id": "displayName", "value": "VM / Model"},
                {"id": "mappings", "value": [vm_value_mapping]}
            ]
        })


def patch_vm_health_dashboard(path, mapping_list):
    """Patch the VM Model Health dashboard: populate Model variable and add legends."""
    if not os.path.exists(path):
        print(f"    Skipping {os.path.basename(path)} (file not found)")
        return

    with open(path, 'r') as f:
        dashboard = json.load(f)

    # 1. Replace the custom Model variable with real model:UUID entries
    for var in dashboard.get('templating', {}).get('list', []):
        if var.get('name') == 'Model' and var.get('type') == 'custom':
            # Build the custom query string: "Label1 : value1, Label2 : value2"
            entries = []
            options = []
            for entry in mapping_list:
                label = f"{entry['model']} ({entry['provider']} - {entry['vm_type']})"
                value = entry['guid']
                entries.append(f"{label} : {value}")
                options.append({
                    "selected": False,
                    "text": label,
                    "value": value
                })

            var['query'] = ", ".join(entries)
            var['options'] = [
                {"selected": True, "text": "All", "value": "$__all"}
            ] + options
            var['current'] = {"selected": True, "text": "All", "value": "$__all"}
            var['description'] = "Select a model to see only the VMs serving it."
            break

    # 2. Add label_replace chains to time series panels and update legends
    TABLE_ID = 50
    for panel in dashboard.get('panels', []):
        panel_id = panel.get('id')
        panel_type = panel.get('type')

        if panel_type == 'timeseries':
            for target in panel.get('targets', []):
                original_expr = target.get('expr', '')
                if 'deployment="genai-models"' in original_expr:
                    target['expr'] = build_label_replace_chain(original_expr, mapping_list)
                    target['legendFormat'] = '{{model_name}} ({{ip}})'

        elif panel_id == TABLE_ID:
            add_table_value_mappings(panel, mapping_list)

    with open(path, 'w') as f:
        json.dump(dashboard, f, indent=2)
        f.write('\n')

    print(f"==> Patched {os.path.basename(path)}: Model dropdown + {len(mapping_list)} model legends")


def patch_llm_perf_dashboard(path, mapping_list):
    """Patch the LLM Performance dashboard: label_replace on any remaining VM panels."""
    if not os.path.exists(path):
        print(f"    Skipping {os.path.basename(path)} (file not found)")
        return

    with open(path, 'r') as f:
        dashboard = json.load(f)

    patched = 0
    for panel in dashboard.get('panels', []):
        panel_type = panel.get('type')

        if panel_type == 'timeseries':
            for target in panel.get('targets', []):
                expr = target.get('expr', '')
                if 'deployment="genai-models"' in expr or 'deployment=~"genai' in expr:
                    target['expr'] = build_label_replace_chain(expr, mapping_list)
                    target['legendFormat'] = '{{model_name}} ({{ip}})'
                    patched += 1

        elif panel_type == 'table':
            # Check if it queries genai deployment
            for target in panel.get('targets', []):
                if 'genai' in target.get('expr', ''):
                    add_table_value_mappings(panel, mapping_list)
                    patched += 1
                    break

    with open(path, 'w') as f:
        json.dump(dashboard, f, indent=2)
        f.write('\n')

    if patched > 0:
        print(f"==> Patched {os.path.basename(path)}: {patched} VM-related queries")
    else:
        print(f"==> {os.path.basename(path)}: No VM panels found (already removed?)")


# Patch both dashboards
patch_vm_health_dashboard(vm_health_path, mapping)
patch_llm_perf_dashboard(llm_perf_path, mapping)

PYTHON_SCRIPT

echo ""
echo "==> Done! Dashboards updated with model name mappings."
echo ""
echo "To deploy to Grafana, import the dashboard JSON files:"
echo "  - $VM_HEALTH_DASHBOARD"
echo "  - $LLM_PERF_DASHBOARD"
echo ""
echo "Via Grafana UI: Dashboards > New > Import > paste JSON > Load > Import"
