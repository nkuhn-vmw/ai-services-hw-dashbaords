# AI Services Healthwatch Dashboards

Grafana dashboards for token usage billing and chargeback on [VMware Tanzu AI Services](https://techdocs.broadcom.com/us/en/vmware-tanzu/platform/ai-services/10-3/ai/index.html) with [Healthwatch for Tanzu](https://techdocs.broadcom.com/us/en/vmware-tanzu/platform/healthwatch-for-vmware-tanzu/2-3/healthwatch/index.html).

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
3. Copy the contents of `ai-services-billback-dashboard.json` and paste into the **Import via panel json** window
4. Click **Load**, then **Import**

The dashboard uses the default Prometheus datasource (`"uid": null`), which auto-connects to Healthwatch's Prometheus.

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
