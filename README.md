# llm-d-bench

Production-ready Helm chart for benchmarking `llm-d` inference endpoints on OpenShift using GuideLLM.

## Features

- **Load Testing**: GuideLLM-based benchmarking for vLLM inference endpoints
- **Production-Ready Monitoring**: Dedicated sidecar container for metrics collection
- **Prometheus/Thanos Integration**: Real-time vLLM metrics during benchmarks
- **Interactive Dashboards**: Automated visualization generation (Plotly HTML)
- **Multi-Container Architecture**: Isolated benchmark and monitoring containers
- **Health Checks**: Kubernetes-native liveness and readiness probes
- **Resource Management**: Configurable CPU/memory limits per container
- **Persistent Results**: All results and metrics stored in PVC

## Quick Start

```bash
# Create Hugging Face token secret
oc create secret generic huggingface-token \
  --from-literal=HF_CLI_TOKEN=your-token \
  -n keda

# Create AWS credentials secret for S3 upload (optional)
oc create secret generic aws-credentials \
  --from-literal=AWS_ACCESS_KEY_ID=your-access-key \
  --from-literal=AWS_SECRET_ACCESS_KEY=your-secret-key \
  -n keda

# Run benchmark
helm install my-benchmark ./llm-d-bench \
  --set benchmark.target=http://llm-service:8080 \
  --set benchmark.model=meta-llama/Llama-3.3-70B-Instruct \
  --set 'benchmark.rate={1,50,100}' \
  -n keda

# Monitor
oc logs -f job/my-benchmark -n keda
```

## Configuration

Key parameters in `values.yaml`:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `jobType` | `benchmark` or `cleanup` | `benchmark` |
| `benchmark.target` | Target llm-d endpoint | - |
| `benchmark.model` | Model name | - |
| `benchmark.rate` | Concurrent rates (e.g., `{1,50,100}` with --set) | - |
| `benchmark.data` | Number of requests or token specs (e.g., `{prompt_tokens=1000,output_tokens=1000}` with --set) | `1000` |
| `benchmark.maxSeconds` | Max runtime | `600` |
| `benchmark.nodeSelector` | Node selector for scheduling | See values.yaml |
| `benchmark.affinity` | Node affinity rules (excludes GPU nodes) | See values.yaml |
| `monitoring.enabled` | Enable vLLM metrics collection (sidecar) | `false` |
| `monitoring.sidecar.image.repository` | Monitoring sidecar image | See values.yaml |
| `monitoring.sidecar.resources` | Monitoring container resources | `512Mi/250m CPU` |
| `monitoring.thanosUrl` | Thanos Querier endpoint | See values.yaml |
| `monitoring.collectionInterval` | Metrics collection interval (seconds) | `10` |
| `monitoring.collectNodeMetrics` | Enable node-level metrics (CPU/memory/network) | `true` |
| `pvc.create` | Create PVC for results (set to false to reuse existing) | `false` |
| `pvc.size` | Storage size | `50Gi` |
| `s3.enabled` | Enable S3 upload of results | `false` |
| `s3.bucket` | S3 bucket name | - |
| `s3.endpoint` | S3 endpoint URL | - |
| `s3.region` | S3 region | - |
| `s3.secretName` | Name of the secret with AWS credentials | `aws-credentials` |
| `kueue.enabled` | Enable Kueue batching | `false` |
| `kueue.queueName` | Kueue queue name | `guidellm-jobs` |

## Usage

### With experiment configurations (recommended)
Use pre-configured experiment files from `experiments/` directory:

```bash
# First time: Create PVC (set create: true in experiment file)
helm install qwen-baseline ./llm-d-bench \
  -f llm-d-bench/experiments/qwen-0.6b-baseline.yaml \
  -n llm-d-inference-scheduling

# Subsequent runs: Reuse existing PVC
helm install qwen-test2 ./llm-d-bench \
  -f llm-d-bench/experiments/qwen-0.6b-baseline.yaml \
  --set pvc.create=false \
  -n llm-d-inference-scheduling

# Monitor progress
oc logs -f job/qwen-0.6b-baseline -n llm-d-inference-scheduling
```

### With custom values file
```bash
helm install test ./llm-d-bench -f examples/benchmark-example.yaml -n keda
```

### With command-line parameters
```bash
# Basic benchmark with rate list
helm install my-test ./llm-d-bench \
  --set benchmark.target=http://llm-service:8080 \
  --set benchmark.model=meta-llama/Llama-3.3-70B-Instruct \
  --set 'benchmark.rate={1,50,100}' \
  -n keda

# Advanced benchmark with token specifications
helm install my-test ./llm-d-bench \
  --set benchmark.target=http://llm-service:8080 \
  --set benchmark.model=meta-llama/Llama-3.3-70B-Instruct \
  --set 'benchmark.rate={1,50,100,200}' \
  --set 'benchmark.data={prompt_tokens=1000,output_tokens=1000}' \
  -n keda
```

### S3 Upload and Kueue Integration
```bash
# Run benchmark with S3 upload enabled
helm install my-benchmark ./llm-d-bench \
  --set benchmark.target=http://llm-service:8080 \
  --set benchmark.model=meta-llama/Llama-3.3-70B-Instruct \
  --set s3.enabled=true \
  --set s3.bucket=my-results-bucket \
  --set s3.endpoint=https://s3.my-region.amazonaws.com \
  --set s3.region=my-region \
  -n keda

# Run benchmark with Kueue batching enabled
helm install my-batch-job ./llm-d-bench \
  --set benchmark.target=http://llm-service:8080 \
  --set benchmark.model=meta-llama/Llama-3.3-70B-Instruct \
  --set kueue.enabled=true \
  --set kueue.queueName=my-custom-queue \
  -n keda
```


**Note:** When using `--set` with comma-separated values, wrap them in curly braces `{value1,value2}` so Helm handles them correctly.

### Cleanup results
```bash
helm install cleanup ./llm-d-bench -f examples/cleanup-example.yaml -n keda
```

## Results

Results are stored in the PVC under `/results/run_<timestamp>/`:
- `console.log` - Execution logs
- `output.json` - Benchmark results

Access results:
```bash
# Browse PVC
oc run -it --rm pvc-browser --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"pvc-browser","image":"busybox","command":["sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"data","mountPath":"/results"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"guidellm-pvc"}}]}}' \
  -n keda
```

## Monitoring

The chart supports comprehensive monitoring during benchmark execution using a **production-ready sidecar pattern**. The monitoring sidecar runs alongside the benchmark container, collecting vLLM metrics from Prometheus/Thanos and node-level resource utilization.

### Architecture

```
┌──────────────────────────────────────────┐
│         Kubernetes Pod                   │
│                                          │
│  ┌─────────────┐  ┌─────────────────┐   │
│  │ GuideLLM    │  │ Monitoring      │   │
│  │ Benchmark   │◄─┤ Sidecar         │   │
│  │             │  │ - Metrics       │   │
│  │             │  │ - Visualization │   │
│  └─────────────┘  └─────────────────┘   │
│         │                │               │
│         └────────┬───────┘               │
│           Shared PVC                     │
└──────────────────────────────────────────┘
```

### Enabling Monitoring

Add to your experiment configuration:

```yaml
monitoring:
  enabled: true

  # Sidecar container configuration
  sidecar:
    image:
      repository: "your-registry.com/vllm-metrics-collector"
      tag: "latest"
    resources:
      requests:
        memory: "512Mi"
        cpu: "250m"
      limits:
        memory: "1Gi"
        cpu: "500m"

  # Monitoring configuration
  thanosUrl: "http://thanos-querier.openshift-monitoring.svc.cluster.local:9091"
  collectionInterval: 10  # seconds
  collectNodeMetrics: true  # Enable CPU, memory, network, disk monitoring
  logLevel: "INFO"
```

### How It Works

When monitoring is enabled:
1. **Separate Container**: A dedicated monitoring sidecar runs alongside the benchmark container
2. **Lifecycle Coordination**: Containers signal each other via shared files for start/stop
3. **Metrics Collection**: Sidecar queries vLLM metrics from Thanos/Prometheus in real-time
4. **Node Monitoring**: Optional node-level metrics (CPU, memory, network, disk I/O)
5. **Health Checks**: Kubernetes liveness and readiness probes monitor sidecar health
6. **Output**: Metrics saved to CSV and JSON files in `/results/run_*/metrics/`
7. **Visualization**: Interactive HTML dashboards automatically generated on completion

### Collected Metrics

**vLLM Metrics** (from Prometheus/Thanos):
- Request queue status (running, waiting, swapped)
- GPU/CPU cache usage percentage
- Throughput (prompt and generation tokens/second)
- Latency metrics (TTFT, TPOT, E2E)
- Token counts and preemptions

**Node Metrics** (from psutil):
- CPU usage and core count
- Memory usage (total, used, available, percentage)
- Network throughput (transmit/receive MB/s)
- Disk I/O (read/write operations and bytes)
- Disk usage

### Visualization

The monitoring system automatically generates two interactive HTML dashboards:
- **`metrics_*_dashboard.html`** - Comprehensive multi-panel dashboard with all metrics over time
- **`metrics_*_summary.html`** - Statistical summary table (mean, median, P95, P99, etc.)

Open these files in a browser for interactive exploration of your benchmark metrics.

### Example

```bash
helm install qwen-monitored ./llm-d-bench \
  -f llm-d-bench/experiments/qwen-0.6b-with-monitoring.yaml \
  -n llm-d-inference-scheduling
```

Results will include:
- `/results/run_<timestamp>/output.json` - GuideLLM benchmark results
- `/results/run_<timestamp>/metrics/metrics_<timestamp>.csv` - Time-series metrics data
- `/results/run_<timestamp>/metrics/metrics_<timestamp>.json` - Complete metrics with metadata
- `/results/run_<timestamp>/metrics/metrics_<timestamp>_dashboard.html` - Interactive dashboard
- `/results/run_<timestamp>/metrics/metrics_<timestamp>_summary.html` - Summary statistics

### Manual Visualization

You can also generate visualizations manually from any metrics CSV file:

```bash
# Inside the container or locally with the script
/usr/local/bin/plot_vllm_metrics.py /path/to/metrics.csv --output-dir /path/to/output
```

## Building Images

The system uses **two container images** for production-ready operation:

### 1. GuideLLM Benchmark Container
```bash
cd llm-d-bench/build/
docker build -f Dockerfile -t guidellm-runner:latest .
docker push your-registry.com/guidellm-runner:latest
```

### 2. Monitoring Sidecar Container
```bash
cd llm-d-bench/build/monitoring/
docker build -t vllm-metrics-collector:latest .
docker push your-registry.com/vllm-metrics-collector:latest
```

### Quick Build Script
Build both images with a single command:
```bash
cd llm-d-bench/build/
./build-all.sh your-registry.com your-namespace latest
```

**See:**
- [build/README.md](llm-d-bench/build/README.md) - Build instructions and image details
- [build/monitoring/README.md](llm-d-bench/build/monitoring/README.md) - Monitoring sidecar documentation
- [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md) - Upgrading from background process to sidecar

## Adding Benchmark Tools

See [ADDING_BENCHMARKS.md](llm-d-bench/ADDING_BENCHMARKS.md).

## Experiments

Pre-configured benchmark experiments are available in `llm-d-bench/experiments/`:
- `qwen-0.6b-baseline.yaml` - Qwen 0.6B baseline benchmark
- `benchmark-example.yaml` - General example configuration

Create your own experiment files in this directory for repeatable benchmark scenarios.

## Copy results

Use the `cp.sh` script to copy the benchmark outputs to your local machine. 

## Documentation

- `llm-d-bench/values.yaml` - Full configuration options
- `llm-d-bench/experiments/` - Pre-configured experiment files
- `llm-d-bench/examples/` - Example configurations
- `llm-d-bench/ADDING_BENCHMARKS.md` - Adding new tools
- `QUICKSTART_MONITORING.md` - 5-minute monitoring setup guide
- `llm-d-bench/MONITORING.md` - Complete monitoring documentation
