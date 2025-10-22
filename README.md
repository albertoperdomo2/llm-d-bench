# LLM Distributed Benchmark (llm-d-bench)

A comprehensive Helm chart solution for benchmarking `llm-d` inference endpoints on OpenShift. Deploy distributed benchmark jobs using GuideLLM with support for multiple benchmark tools.

## Repository Structure

```
.
├── llm-d-bench/                # Helm chart for deploying benchmark jobs
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── templates/
│   │   ├── benchmarks/
│   │   │   ├── _common/        # Shared templates (PVC)
│   │   │   └── guidellm/       # GuideLLM benchmark
│   │   ├── NOTES.txt
│   │   └── _helpers.tpl
│   ├── examples/               # Example values files
│   ├── build/                  # Container image build configs
│   │   ├── Dockerfile
│   │   ├── buildconfig.yaml
│   │   └── imagestream.yaml
│   └── README.md               # Detailed chart documentation
├── ARCHITECTURE.md             # System architecture
├── QUICKSTART.md               # Quick reference guide
└── Makefile                    # Build automation
```

## Quick Start

### Prerequisites

- OpenShift 4.x
- Helm 3.0+
- A Hugging Face token for model access

### 1. Create Required Secrets

```bash
oc create secret generic huggingface-token \
  --from-literal=HF_CLI_TOKEN=your-hf-token-here \
  -n keda
```

### 2. Deploy a Benchmark Job

```bash
helm install my-benchmark ./llm-d-bench \
  --set jobType=benchmark \
  --set benchmark.target=http://your-llm-service:8080 \
  --set benchmark.model=meta-llama/Llama-3.3-70B-Instruct \
  --set benchmark.rate="1,50,100" \
  --set pvc.create=true \
  -n keda
```

### 3. Monitor the Job

```bash
oc logs job/my-benchmark-benchmark -n keda -f
```

## Features

- **Multiple Benchmark Tools**: Extensible architecture supporting different tools (GuideLLM default)
- **OpenShift Native**: Includes BuildConfig and ImageStream for custom images
- **Job Types**: Deploy benchmark or cleanup jobs
- **Automatic PVC Management**: Creates and manages persistent storage for results
- **Configurable Parameters**: Customize benchmarks, resources, and behavior
- **Production Ready**: Includes resource limits, retries, and monitoring

## Usage Examples

### Run a Simple Benchmark

```bash
helm install llama-test ./llm-d-bench \
  --set jobType=benchmark \
  --set benchmark.target=http://llama-service:8080 \
  --set benchmark.model=meta-llama/Llama-3.3-70B-Instruct \
  --set benchmark.rate="1,50,100" \
  -n keda
```

### Use a Custom Values File

```bash
helm install custom-benchmark ./llm-d-bench \
  -f llm-d-bench/examples/benchmark-example.yaml \
  -n keda
```

### Deploy a Cleanup Job

```bash
helm install cleanup ./llm-d-bench \
  -f llm-d-bench/examples/cleanup-example.yaml \
  -n keda
```

### Create Only the PVC

```bash
helm install storage ./llm-d-bench \
  -f llm-d-bench/examples/pvc-only-example.yaml \
  -n keda
```

## Configuration

Key configuration options (see `llm-d-bench/values.yaml` for full details):

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| `benchmarkTool` | Benchmark tool to use | `guidellm` | No |
| `jobType` | Type of job: `benchmark` or `cleanup` | `benchmark` | Yes |
| `benchmark.name` | Benchmark job name | `guidellm-test` | No |
| `benchmark.target` | LLM service endpoint URL | `""` | Yes (for benchmark) |
| `benchmark.model` | Model name for benchmarking | `""` | Yes (for benchmark) |
| `benchmark.processor` | Processor/tokenizer model | `""` | No |
| `benchmark.backendType` | Backend type (e.g., openai_http) | `openai_http` | No |
| `benchmark.rateType` | Rate type (concurrent, synchronous, etc.) | `concurrent` | No |
| `benchmark.rate` | Rate values (e.g., "1,50,100,200") | `""` | No |
| `benchmark.data` | Number of requests or data points | `1000` | No |
| `benchmark.maxSeconds` | Maximum seconds to run | `600` | No |
| `benchmark.additionalArgs` | Additional GuideLLM arguments | `""` | No |
| `benchmark.env` | Environment variables (GUIDELLM__ prefixed) | See values.yaml | No |
| `pvc.create` | Create a new PVC | `true` | No |
| `pvc.name` | PVC name | `guidellm-pvc` | No |
| `pvc.size` | Storage size for results | `50Gi` | No |

## Accessing Results

Benchmark results are stored in the PVC under timestamped directories:

```
/results/
├── run_1234567890/
│   ├── console.log      # Job execution logs
│   └── output.json      # Benchmark results
├── run_1234567891/
│   ├── console.log
│   └── output.json
...
```

To access results:

```bash
# Create a debug pod to browse results
oc run -it --rm pvc-browser \
  --image=busybox \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "pvc-browser",
      "image": "busybox",
      "command": ["sh"],
      "stdin": true,
      "tty": true,
      "volumeMounts": [{
        "name": "data",
        "mountPath": "/results"
      }]
    }],
    "volumes": [{
      "name": "data",
      "persistentVolumeClaim": {
        "claimName": "guidellm-pvc"
      }
    }]
  }
}' \
  -n keda

# Or copy results locally
POD=$(oc get pods -n keda -l job-name=my-benchmark-benchmark -o jsonpath='{.items[0].metadata.name}')
oc cp keda/$POD:/results/run_* ./local-results/
```

## Building Custom Images

The chart includes OpenShift BuildConfig and ImageStream for building custom benchmark images:

```bash
# Apply image build resources
oc apply -f llm-d-bench/build/imagestream.yaml
oc apply -f llm-d-bench/build/buildconfig.yaml

# Start the build
oc start-build guidellm-runner -n keda

# Watch the build
oc logs -f bc/guidellm-runner -n keda

# Verify the image
oc get imagestream guidellm-runner -n keda
```

Alternatively, build with Docker/Podman:

```bash
docker build -f llm-d-bench/build/Dockerfile -t guidellm-runner:latest .
```

## Adding New Benchmark Tools

The chart supports multiple benchmark tools through a modular template structure. To add a new tool:

1. Create directory: `templates/benchmarks/your-tool/`
2. Add benchmark job template with conditional rendering
3. Create example values file
4. Update documentation

See [ADDING_BENCHMARKS.md](llm-d-bench/ADDING_BENCHMARKS.md) for detailed instructions.

## Documentation

- [Helm Chart README](llm-d-bench/README.md) - Comprehensive chart documentation
- [Adding Benchmarks Guide](llm-d-bench/ADDING_BENCHMARKS.md) - How to add new benchmark tools
- [Example Values](llm-d-bench/examples/) - Pre-configured examples

## Troubleshooting

### Job Fails to Start

Check if the required secret exists:
```bash
oc get secret huggingface-token -n keda
```

### PVC Not Bound

Check storage class availability:
```bash
oc get storageclass
oc describe pvc guidellm-pvc -n keda
```

### Cannot Access LLM Service

Verify network connectivity and service URL:
```bash
oc run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://your-llm-service:8080/v1/models
```

### Build Fails

Check build logs:
```bash
oc logs -f bc/guidellm-runner -n keda
```

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

Apache 2.0

## Support

For issues, questions, or contributions, please open an issue in the repository.
