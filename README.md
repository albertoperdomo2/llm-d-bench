# llm-d-bench

Helm chart for benchmarking `llm-d` inference endpoints on OpenShift using GuideLLM.

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
| `benchmark.target` | Target llm-d endpoint | - |
| `benchmark.model` | Model name | - |
| `benchmark.rate` | Concurrent rates (e.g., `{1,50,100}` with --set) | - |
| `benchmark.data` | Number of requests or token specs (e.g., `{prompt_tokens=1000,output_tokens=1000}` with --set) | `1000` |
| `benchmark.maxSeconds` | Max runtime | `600` |
| `benchmark.nodeSelector` | Node selector for scheduling | See values.yaml |
| `benchmark.affinity` | Node affinity rules (excludes GPU nodes) | See values.yaml |
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
  -n llm-d-inference-scheduler

# Subsequent runs: Reuse existing PVC
helm install qwen-test2 ./llm-d-bench \
  -f llm-d-bench/experiments/qwen-0.6b-baseline.yaml \
  --set pvc.create=false \
  -n llm-d-inference-scheduler

# Monitor progress
oc logs -f job/qwen-0.6b-baseline -n llm-d-inference-scheduler
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

## Results

Results are stored in the PVC under `/results/run_<timestamp>/`:
- `console.log` - Execution logs
- `output.json` - Benchmark results

If S3 upload is enabled, results are automatically uploaded to your configured S3 bucket.

### Accessing Results Locally (Optional)

If you need to access results directly from the PVC:

```bash
# Browse PVC
oc run -it --rm pvc-browser --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"pvc-browser","image":"busybox","command":["sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"data","mountPath":"/results"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"guidellm-pvc"}}]}}' \
  -n keda

# Or use the sync.sh script to copy results to your local machine
./synch.sh run_<timestamp>
```

## Adding Benchmark Tools

See [ADDING_BENCHMARKS.md](llm-d-bench/ADDING_BENCHMARKS.md).

## Experiments

Pre-configured benchmark experiments are available in `llm-d-bench/experiments/`:
- `qwen-0.6b-baseline.yaml` - Qwen 0.6B baseline benchmark
- `benchmark-example.yaml` - General example configuration

Create your own experiment files in this directory for repeatable benchmark scenarios.

> [!IMPORTANT]
> Experiment filenames must not contain periods (`.`) except for the `.yaml` extension. Use hyphens (`-`) or underscores (`_`) instead.
> - Good: `my-experiment-v2.yaml`, `qwen_test.yaml`
> - Bad: `my.experiment.yaml`, `test-v1.2.yaml`

## Documentation

- `llm-d-bench/values.yaml` - Full configuration options
- `llm-d-bench/experiments/` - Pre-configured experiment files
- `llm-d-bench/examples/` - Example configurations
- `llm-d-bench/ADDING_BENCHMARKS.md` - Adding new tools
