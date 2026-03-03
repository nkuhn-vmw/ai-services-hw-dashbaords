# AI Services Healthwatch Dashboards

Grafana dashboards for monitoring and billing of [VMware Tanzu AI Services](https://techdocs.broadcom.com/us/en/vmware-tanzu/platform/ai-services/10-3/ai/index.html) with [Healthwatch for Tanzu](https://techdocs.broadcom.com/us/en/vmware-tanzu/platform/healthwatch-for-vmware-tanzu/2-3/healthwatch/index.html).

## Dashboards

### AI Services - Token Usage Billback

**File:** `ai-services-billback-dashboard.json`

A chargeback/billback dashboard that breaks down AI token usage by Cloud Foundry organization, space, LLM model, and service plan/endpoint.

#### Features

- **Organization & Space dropdowns** with human-readable names (resolved from container metrics via `group_left` join)
- **LLM Model filter** (e.g., `openai/gpt-oss-120b`, `Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8`)
- **Endpoint / Plan filter** (e.g., `tanzu-all-models-a8a9e22`, `tanzu-gpt-oss-120b-vllm-v1-0d28358`)
- Summary stats: total input, output, and combined tokens for the selected time period
- Bar charts and time series by org, space, model, and endpoint
- Detailed billback table with input/output/total token breakdown
- Raw data fallback section for spaces without running app instances

#### How org/space name resolution works

The `ai_server_client_token_usage_total` metric only contains `platform_cf_space_guid` (not names). This dashboard uses a PromQL `group_left` join with the `cpu` container metric (which has `organization_name`, `space_name`, `space_id`) to resolve GUIDs to human-readable names.

This works for any space that has at least one running app instance. The collapsed "Raw Data" section shows all data by GUID as a fallback.

## Prerequisites

- GenAI / AI Services tile v10.0.0 or later
- Healthwatch and Healthwatch Exporter tiles v2.3.1 or later

## Installation

1. Log in to Grafana at `https://grafana.<SYSTEM_DOMAIN>`
   - Credentials are in Ops Manager under the Healthwatch tile > Credentials tab > Grafana Credentials
2. Navigate to **Dashboards > New > Import**
3. Copy the contents of the desired dashboard JSON and paste into the **Import via panel json** window
4. Click **Load**, then **Import**

Both dashboards use the default Prometheus datasource (`"uid": null`), which auto-connects to Healthwatch's Prometheus.

**For the LLM Performance dashboard:** To show model names on VM panels instead of UUIDs, run the mapping script before importing:

```bash
./scripts/configure-vm-model-mapping.sh -e /path/to/om-env.yml
```

Then import the patched `ai-services-llm-performance-dashboard.json`.

## Metrics Used

| Metric | Description |
|--------|-------------|
| `ai_server_client_token_usage_total` | Cumulative token count by model, endpoint, token type, space, and app |
| `ai_server_requests_seconds_count` | Request count |
| `ai_server_requests_active_seconds_count` | Active request count |
| `cpu` | Container CPU metric (used for org/space name resolution via `group_left` join) |

### Key labels on `ai_server_client_token_usage_total`

| Label | Description |
|-------|-------------|
| `gen_ai_token_type` | `input`, `output`, or `total` |
| `ai_server_advertised_model` | LLM model name |
| `ai_server_endpoint` | Service endpoint / plan name |
| `platform_cf_space_guid` | CF space GUID |
| `platform_cf_app_guid` | CF app GUID of the consuming application |
| `platform_cf_service_instance_guid` | CF service instance GUID |

---

### AI Services - LLM Performance

**File:** `ai-services-llm-performance-dashboard.json`

A centralized operations dashboard for monitoring LLM health and performance. Select a model (e.g., `openai/gpt-oss-120b`) and see consolidated performance across all plans/endpoints serving it, plus the underlying VM resources.

#### Features

- **Model & Endpoint dropdowns** - select a model to see consolidated stats across all plans mapped to it
- **Health summary** - VM health status, request count, error rate, avg response time, avg TTFT, token counts, active plan count
- **Request performance** - request rate, avg response time, time to first token (TTFT), max active request duration over time, all by model
- **Token throughput** - input/output tokens per minute, broken down by model
- **Error analysis** - errors by type (TooManyRequests, IOException, etc.), error rate by model with 5% threshold line
- **Per-endpoint breakdown** - request rate and response time by service plan/endpoint
- **Model-serving VM resources** - CPU, memory, system load, persistent/ephemeral disk usage for the `genai-models` BOSH deployment VMs, labeled with model names
- **VM status table** - at-a-glance table of all GenAI VMs with health, CPU, memory, load, disk, and swap

#### VM-to-Model name mapping

The `genai-models` BOSH VMs use UUID job names (`exported_job` label) with no built-in association to the LLM model they serve. The included script `scripts/configure-vm-model-mapping.sh` queries OpsManager to discover this mapping and patches the dashboard JSON so VM panels display model names (e.g., `openai/gpt-oss-120b`) instead of UUIDs.

**How it works:** The GenAI tile stores model configurations in `.errands.vllm_models` and `.errands.ollama_models` tile properties. Each model config contains a `guid` field that matches the BOSH VM `exported_job` label. The script extracts these GUIDs and patches the dashboard with:
- `label_replace` PromQL functions on time series panels to add a `model_name` label
- Grafana value mappings on the VM status table to display model names

**Usage:**

```bash
# Requires: om CLI, jq, python3
./scripts/configure-vm-model-mapping.sh -e /path/to/om-env.yml

# With custom dashboard path
./scripts/configure-vm-model-mapping.sh -e /path/to/om-env.yml -d /path/to/dashboard.json
```

The om env file should contain your OpsManager connection details:

```yaml
---
target: https://opsman.example.com
username: admin
password: <password>
skip-ssl-validation: true
```

**Re-running after model changes:** If models are added, removed, or reconfigured in the AI Services tile, restore the clean dashboard from git and re-run:

```bash
git checkout -- ai-services-llm-performance-dashboard.json
./scripts/configure-vm-model-mapping.sh -e /path/to/om-env.yml
```

#### Metrics used

| Metric | Description |
|--------|-------------|
| `ai_server_requests_seconds_count/sum` | Request count and total duration (has `error` label) |
| `ai_server_requests_active_seconds_max` | Max active request duration |
| `gen_ai_server_time_to_first_token_seconds_count/sum` | Time to first token (TTFT) |
| `gen_ai_client_operation_seconds_count/sum` | Client-side operation duration |
| `ai_server_client_token_usage_total` | Token consumption (input/output) |
| `system_cpu_user`, `system_cpu_sys` | BOSH VM CPU utilization |
| `system_mem_percent`, `system_mem_kb` | BOSH VM memory utilization |
| `system_load_1m` | BOSH VM system load average |
| `system_disk_persistent_percent` | BOSH VM persistent disk (model storage) |
| `system_disk_ephemeral_percent` | BOSH VM ephemeral disk |
| `system_healthy` | BOSH VM health status |
