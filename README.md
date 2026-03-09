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

All dashboards use the default Prometheus datasource (`"uid": null`), which auto-connects to Healthwatch's Prometheus.

**For the VM Model Health dashboard:** Run the mapping script before importing to populate the Model dropdown with your foundation's models:

```bash
./scripts/configure-vm-model-mapping.sh -e /path/to/om-env.yml
```

Then import the patched dashboard JSON files.

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

### AI Services - AI Server Health

**File:** `ai-services-ai-server-health-dashboard.json`

Application-level health monitoring for the AI Server process, covering JVM internals, HTTP traffic, database connection pooling, and the controller VM.

#### Features

- **Server Overview** - controller VM health, process uptime, CPU usage, live threads, GC overhead, open file descriptors, log errors/warnings
- **HTTP Traffic** - request rate by status code (2xx/4xx/5xx), avg response time by endpoint, request rate by endpoint, 5xx error rate with threshold
- **JVM Memory** - heap used vs committed, non-heap used vs committed, heap breakdown by memory pool (Eden/Survivor/Old Gen), GC pause rate & duration
- **Database Connection Pool (HikariCP)** - active/idle/pending/max connections, pool timeouts
- **Threads & Logging** - thread states (runnable, waiting, blocked), log events by level (error, warn, info, debug)
- **Controller VM Resources** - CPU, memory, and disk utilization for the controller VM
- Links to **LLM Performance**, **VM Model Health**, and **Token Billback** dashboards

#### Metrics used

| Metric | Description |
|--------|-------------|
| `jvm_memory_used_bytes`, `jvm_memory_committed_bytes` | JVM heap and non-heap memory |
| `jvm_gc_pause_seconds_count/sum` | Garbage collection frequency and duration |
| `jvm_threads_live_threads`, `jvm_threads_states_threads` | JVM thread counts by state |
| `hikaricp_connections_active/idle/pending/max` | HikariCP database connection pool |
| `hikaricp_connections_timeout_total` | Pool timeout events |
| `http_server_requests_seconds_count/sum` | HTTP request count and duration by status, URI, method |
| `logback_events_total` | Log event counts by level |
| `process_cpu_usage`, `process_uptime_seconds` | Process-level CPU and uptime |
| `system_cpu_user`, `system_mem_percent`, `system_disk_*_percent` | Controller VM resources |

---

### AI Services - LLM Performance

**File:** `ai-services-llm-performance-dashboard.json`

A centralized operations dashboard for monitoring LLM health and performance. Select a model (e.g., `openai/gpt-oss-120b`) and see consolidated performance across all plans/endpoints serving it.

#### Features

- **Model & Endpoint dropdowns** - select a model to see consolidated stats across all plans mapped to it
- **Health summary** - VM health status, request count, error rate, avg response time, avg TTFT, token counts, active plan count
- **Request performance** - request rate, avg response time, time to first token (TTFT), max active request duration over time, all by model
- **Token throughput** - input/output tokens per minute, broken down by model
- **Error analysis** - errors by type (TooManyRequests, IOException, etc.), error rate by model with 5% threshold line
- **Per-endpoint breakdown** - request rate and response time by service plan/endpoint
- Links to the **VM Model Health** dashboard for underlying VM resources

#### Metrics used

| Metric | Description |
|--------|-------------|
| `ai_server_requests_seconds_count/sum` | Request count and total duration (has `error` label) |
| `ai_server_requests_active_seconds_max` | Max active request duration |
| `gen_ai_server_time_to_first_token_seconds_count/sum` | Time to first token (TTFT) |
| `gen_ai_client_operation_seconds_count/sum` | Client-side operation duration |
| `ai_server_client_token_usage_total` | Token consumption (input/output) |

---

### AI Services - VM Model Health

**File:** `ai-services-vm-model-health-dashboard.json`

Detailed VM-level health and resource monitoring for the BOSH VMs serving LLM models. Select a model from the dropdown to see only the VMs running that model (a model can have 1-10+ worker VMs).

#### Features

- **Model dropdown** - select a model to filter to only its VMs; shows model name, provider (vllm/ollama), and VM type
- **Health summary** - VM count, health status, avg CPU/memory/load/disk, max swap
- **CPU & Load** - per-VM CPU utilization and system load over time
- **Memory** - per-VM memory percentage and absolute usage
- **Disk** - persistent, ephemeral, and system disk usage per VM
- **Swap** - swap usage over time (high swap degrades inference performance)
- **VM status table** - at-a-glance table with health, CPU, memory, load, disk, and swap

#### VM-to-Model name mapping

The `genai-models` BOSH VMs use UUID job names (`exported_job` label) with no built-in association to the LLM model they serve. The included script `scripts/configure-vm-model-mapping.sh` queries OpsManager to discover this mapping and patches both dashboard JSON files:

- **VM Model Health dashboard**: Populates the Model dropdown with `model_name : vm_uuid` entries, adds `label_replace` chains for model-name legends, and value mappings on the table
- **LLM Performance dashboard**: Applies model-name labels to any remaining VM-related queries

**How it works:** The GenAI tile stores model configurations in `.errands.vllm_models` and `.errands.ollama_models` tile properties. Each model config contains a `guid` field that matches the BOSH VM `exported_job` label.

**Usage:**

```bash
# Requires: om CLI, jq, python3
./scripts/configure-vm-model-mapping.sh -e /path/to/om-env.yml
```

The om env file should contain your OpsManager connection details:

```yaml
---
target: https://opsman.example.com
username: admin
password: <password>
skip-ssl-validation: true
```

**Re-running after model changes:** If models are added, removed, or reconfigured in the AI Services tile, restore the clean dashboards from git and re-run:

```bash
git checkout -- ai-services-vm-model-health-dashboard.json ai-services-llm-performance-dashboard.json
./scripts/configure-vm-model-mapping.sh -e /path/to/om-env.yml
```

#### Metrics used

| Metric | Description |
|--------|-------------|
| `system_cpu_user`, `system_cpu_sys` | BOSH VM CPU utilization |
| `system_mem_percent`, `system_mem_kb` | BOSH VM memory utilization |
| `system_load_1m` | BOSH VM system load average |
| `system_disk_persistent_percent` | BOSH VM persistent disk (model storage) |
| `system_disk_ephemeral_percent` | BOSH VM ephemeral disk |
| `system_disk_system_percent` | BOSH VM system disk |
| `system_swap_percent` | BOSH VM swap usage |
| `system_healthy` | BOSH VM health status |

---

### AI Services - Postgres Health

**File:** `ai-services-postgres-health-dashboard.json`

Health monitoring for the 6 on-demand Postgres service instances backing AI Services. Covers both Postgres-level metrics (from `postgres_exporter`) and BOSH VM resources.

#### Features

- **Instance dropdown** - filter by deployment name (Postgres service instance) with All option
- **Instance Overview** - instances up, total DB size, total backends, cache hit ratio, transaction rate, deadlocks
- **Connections** - connections by state (stacked), connections vs max_connections (with red dashed limit line)
- **Transaction Performance** - commit vs rollback rate (green/red), cache hit ratio over time with 95% threshold
- **Tuple Operations** - fetched/inserted/updated/deleted rates, temp files & bytes
- **Locks & Long Transactions** - locks by mode (stacked bars), max transaction duration by state
- **WAL & Checkpoints** - WAL size over time, checkpoint rate (timed/requested) with bgwriter buffer stats
- **VM Resources** - CPU, memory, and disk utilization per Postgres VM
- **Table Statistics** (collapsed) - top tables by size (bar gauge), dead tuples needing vacuum
- Links to **AI Server Health**, **LLM Performance**, **VM Model Health**, and **Token Billback** dashboards

#### Metrics used

| Metric | Description |
|--------|-------------|
| `pg_up` | Postgres exporter health (1 = up) |
| `pg_database_size_bytes` | Database size on disk |
| `pg_stat_database_numbackends` | Active backend connections |
| `pg_stat_database_blks_hit/read` | Buffer cache hits and disk reads |
| `pg_stat_database_xact_commit/rollback` | Transaction commit and rollback counts |
| `pg_stat_database_deadlocks` | Deadlock count |
| `pg_stat_database_tup_fetched/inserted/updated/deleted` | Tuple operation counts |
| `pg_stat_database_temp_files/bytes` | Temporary file usage |
| `pg_stat_activity_count` | Connections by state |
| `pg_stat_activity_max_tx_duration_seconds` | Longest running transaction |
| `pg_settings_max_connections` | Configured connection limit |
| `pg_locks_count` | Lock counts by mode |
| `pg_wal_size_bytes` | Write-Ahead Log size |
| `pg_stat_bgwriter_checkpoints_timed/req_total` | Checkpoint frequency |
| `pg_stat_bgwriter_buffers_checkpoint/clean_total` | Bgwriter buffer writes |
| `pg_stat_user_tables_size_bytes` | Table sizes |
| `pg_stat_user_tables_n_dead_tup` | Dead tuples per table |
| `system_cpu_user`, `system_cpu_sys` | VM CPU utilization |
| `system_mem_percent` | VM memory utilization |
| `system_disk_persistent/ephemeral_percent` | VM disk utilization |
