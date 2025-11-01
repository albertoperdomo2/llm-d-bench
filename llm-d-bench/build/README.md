# Building Custom Benchmark Images

This directory contains the resources needed to build custom container images for the LLM-D Benchmark suite on OpenShift.

## Container Images

The benchmark system uses a **multi-container architecture** for production-ready operation:

### 1. GuideLLM Benchmark Container (`guidellm-runner`)
Main benchmark execution container that runs load tests against vLLM inference endpoints.

**Location**: `./Dockerfile`

### 2. Monitoring Sidecar Container (`vllm-metrics-collector`)
Production-ready sidecar for collecting vLLM and node metrics during benchmarks.

**Location**: `./monitoring/` ([See monitoring README](./monitoring/README.md))

## Files

### Benchmark Container
- **Dockerfile** - GuideLLM benchmark image definition
- **buildconfig.yaml** - OpenShift BuildConfig resource
- **imagestream.yaml** - OpenShift ImageStream resource

### Monitoring Sidecar
- **monitoring/Dockerfile** - Monitoring sidecar image definition
- **monitoring/entrypoint.sh** - Container coordination and lifecycle management
- **monitoring/vllm_metrics_collector.py** - Metrics collection from Prometheus/Thanos
- **monitoring/plot_vllm_metrics.py** - Visualization generation
- **monitoring/requirements.txt** - Python dependencies
- **monitoring/README.md** - Comprehensive documentation

## Quick Start

### Using OpenShift BuildConfig

```bash
# Apply the resources
oc apply -f imagestream.yaml -n keda
oc apply -f buildconfig.yaml -n keda

# Start a build
oc start-build guidellm-runner -n keda

# Watch the build progress
oc logs -f bc/guidellm-runner -n keda

# Verify the built image
oc get imagestream guidellm-runner -n keda
oc describe imagestream guidellm-runner -n keda
```

### Building Benchmark Container with Docker/Podman

```bash
# Build the GuideLLM benchmark image
docker build -f Dockerfile -t guidellm-runner:latest .

# Or with Podman
podman build -f Dockerfile -t guidellm-runner:latest .

# Tag and push to your registry
docker tag guidellm-runner:latest your-registry.com/guidellm-runner:latest
docker push your-registry.com/guidellm-runner:latest
```

### Building Monitoring Sidecar Container

```bash
# Navigate to monitoring directory
cd monitoring/

# Build the monitoring sidecar image
docker build -t vllm-metrics-collector:latest .

# Tag for OpenShift internal registry
docker tag vllm-metrics-collector:latest \
  image-registry.openshift-image-registry.svc:5000/llm-d-inference-scheduling/vllm-metrics-collector:latest

# Push to registry
docker push image-registry.openshift-image-registry.svc:5000/llm-d-inference-scheduling/vllm-metrics-collector:latest
```

**See [monitoring/README.md](./monitoring/README.md) for detailed monitoring setup documentation.**

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes Pod                        │
│                                                          │
│  ┌───────────────────┐      ┌───────────────────────┐  │
│  │ GuideLLM          │      │ Monitoring Sidecar    │  │
│  │ Benchmark         │◄────►│ (Optional)            │  │
│  │                   │      │                       │  │
│  │ - Load Testing    │      │ - Metrics Collection  │  │
│  │ - Result Analysis │      │ - Visualization       │  │
│  └───────────────────┘      └───────────────────────┘  │
│           │                           │                 │
│           └───────────┬───────────────┘                 │
│                       │                                 │
│              Shared PVC Volume                          │
│              /results/run_*/                            │
└─────────────────────────────────────────────────────────┘
```

## Image Contents

### GuideLLM Benchmark Container
- Python 3.12-slim base image
- GuideLLM benchmark tool
- System utilities (curl, vim, git, screen, network monitoring tools)
- Python packages: guidellm, requests, pandas, plotly
- Non-root user (UID 1001)

### Monitoring Sidecar Container
- Python 3.12-slim base image
- vLLM metrics collector (queries Prometheus/Thanos API)
- Node metrics collector (CPU, memory, network, disk via psutil)
- Visualization script (generates interactive Plotly dashboards)
- Python packages: requests, pandas, plotly, psutil, prometheus-client
- Health check support
- Non-root user (UID 1001)
- Container coordination via shared state files

## Customization

To customize the image:

1. Edit the `Dockerfile` to add/remove packages or change versions
2. If using BuildConfig, update the `buildconfig.yaml` if needed
3. Rebuild the image using the commands above
4. Update your Helm values to use the new image:

```yaml
benchmark:
  image:
    repository: your-registry.com/guidellm-runner
    tag: your-custom-tag
```

## Troubleshooting

### Build Fails

Check build logs:
```bash
oc logs -f bc/guidellm-runner -n keda
```

Common issues:
- Network connectivity for downloading packages
- Insufficient resources in the build pod
- Git repository access issues

### Image Not Available

Verify the ImageStream:
```bash
oc describe imagestream guidellm-runner -n keda
```

Check that the build completed successfully:
```bash
oc get builds -n keda | grep guidellm-runner
```
