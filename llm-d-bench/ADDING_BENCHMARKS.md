# Adding New Benchmark Tools

This directory contains benchmark tool implementations. Each benchmark tool has its own subdirectory with specific job templates.

## Current Benchmark Tools

- **guidellm/** - GuideLLM benchmark tool (default)
- **_common/** - Shared templates (PVC, etc.)

## Adding a New Benchmark Tool

To add support for a new benchmark tool (e.g., `locust`, `k6`, `artillery`), follow these steps:

### 1. Create Benchmark Directory

```bash
mkdir -p templates/benchmarks/your-benchmark-tool
```

### 2. Create Benchmark Job Template

Create `templates/benchmarks/your-benchmark-tool/benchmark-job.yaml`:

```yaml
{{- if and (eq .Values.jobType "benchmark") (eq .Values.benchmarkTool "your-benchmark-tool") }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "llm-d-bench.benchmarkJobName" . }}
  namespace: {{ include "llm-d-bench.namespace" . }}
  labels:
    {{- include "llm-d-bench.labels" . | nindent 4 }}
    job-type: benchmark
    benchmark-tool: your-benchmark-tool
spec:
  template:
    metadata:
      labels:
        {{- include "llm-d-bench.selectorLabels" . | nindent 8 }}
        job: {{ include "llm-d-bench.benchmarkJobName" . }}
        job-type: benchmark
    spec:
      containers:
      - name: benchmark-container
        image: {{ .Values.benchmark.image.repository }}:{{ .Values.benchmark.image.tag }}
        imagePullPolicy: {{ .Values.benchmark.image.pullPolicy }}
        command: ["/bin/bash"]
        args:
          - -c
          - |
            set -euo pipefail

            # Your benchmark tool commands here
            echo "[JOB] Running your-benchmark-tool..."

            # Save results to PVC
            export RUN_DIR="{{ .Values.pvc.mountPath }}/run_$(date +%s)"
            mkdir -p $${RUN_DIR}

            # Run your benchmark and save output
            your-benchmark-tool run \
              --target {{ .Values.benchmark.targetUrl }} \
              --output $${RUN_DIR}/output.json

            echo "[JOB] Results saved to $${RUN_DIR}"
        volumeMounts:
        - name: results
          mountPath: {{ .Values.pvc.mountPath }}
        resources:
          {{- toYaml .Values.benchmark.resources | nindent 10 }}
      volumes:
      - name: results
        persistentVolumeClaim:
          claimName: {{ include "llm-d-bench.pvcName" . }}
      restartPolicy: Never
  backoffLimit: {{ .Values.benchmark.backoffLimit }}
{{- end }}
```

### 3. Create Cleanup Job Template (Optional)

Create `templates/benchmarks/your-benchmark-tool/cleanup-job.yaml`:

```yaml
{{- if and (eq .Values.jobType "cleanup") (eq .Values.benchmarkTool "your-benchmark-tool") }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "llm-d-bench.cleanupJobName" . }}
  namespace: {{ include "llm-d-bench.namespace" . }}
  labels:
    {{- include "llm-d-bench.labels" . | nindent 4 }}
    job-type: cleanup
    benchmark-tool: your-benchmark-tool
spec:
  template:
    metadata:
      labels:
        {{- include "llm-d-bench.selectorLabels" . | nindent 8 }}
        job: {{ include "llm-d-bench.cleanupJobName" . }}
        job-type: cleanup
    spec:
      containers:
      - name: cleanup-container
        image: {{ .Values.cleanup.image.repository }}:{{ .Values.cleanup.image.tag }}
        command: ["/bin/bash"]
        args:
          - -c
          - |
            set -euo pipefail
            echo "[JOB] Cleaning up benchmark results..."
            rm -rf {{ .Values.pvc.mountPath }}/run_*
            echo "[JOB] Cleanup done!"
        volumeMounts:
        - name: results
          mountPath: {{ .Values.pvc.mountPath }}
      volumes:
      - name: results
        persistentVolumeClaim:
          claimName: {{ include "llm-d-bench.pvcName" . }}
      restartPolicy: Never
  backoffLimit: {{ .Values.cleanup.backoffLimit }}
{{- end }}
```

### 4. Update values.yaml

Add configuration section for your benchmark tool:

```yaml
# In values.yaml

# Set this to your new tool name
benchmarkTool: your-benchmark-tool

benchmark:
  name: my-benchmark
  targetUrl: "http://your-service:8080"

  # Tool-specific configuration
  image:
    repository: your-registry/your-benchmark-tool
    tag: latest
    pullPolicy: Always

  # Add any tool-specific parameters
  parameters:
    duration: 300
    users: 100
    rampUp: 60
```

### 5. Create Example Values File

Create `examples/your-benchmark-tool-example.yaml`:

```yaml
benchmarkTool: your-benchmark-tool
jobType: benchmark

benchmark:
  name: your-tool-test
  targetUrl: http://llm-service:8080

  image:
    repository: your-registry/your-benchmark-tool
    tag: latest

  parameters:
    # Tool-specific parameters
    duration: 600
    users: 500

pvc:
  create: false
  name: llm-d-bench-pvc
```

### 6. Test Your Implementation

```bash
# Lint the chart
helm lint ./llm-d-bench

# Dry-run to see rendered templates
helm template test ./llm-d-bench \
  -f examples/your-benchmark-tool-example.yaml \
  --namespace keda

# Install for real
helm install test ./llm-d-bench \
  -f examples/your-benchmark-tool-example.yaml \
  -n keda
```

### 7. Document Your Tool

Add documentation to the main README about your new benchmark tool:

```markdown
## Supported Benchmark Tools

### GuideLLM (Default)
- Focus on LLM-specific benchmarks
- OpenAI API compatible
- Token-level metrics

### Your Benchmark Tool
- Brief description
- Key features
- Use cases
```

## Template Structure Best Practices

### Use Consistent Naming

- Container names should reflect the tool
- Labels should include `benchmark-tool: <tool-name>`
- Use standard helper functions from `_helpers.tpl`

### Support Common Features

- ✅ PVC mounting for results storage
- ✅ Resource limits and requests
- ✅ Configurable backoff limits
- ✅ Results saved with timestamp
- ✅ Clear logging

### Environment Variables

Access common values through `.Values`:

```yaml
env:
  - name: TARGET_URL
    value: {{ .Values.benchmark.targetUrl }}
  - name: NAMESPACE
    value: {{ include "llm-d-bench.namespace" . }}
```

### Secrets Management

If your tool needs secrets:

```yaml
env:
  - name: API_KEY
    valueFrom:
      secretKeyRef:
        name: {{ .Values.benchmark.secretName }}
        key: {{ .Values.benchmark.secretKey }}
```

## Example: Adding Locust

Here's a complete example for adding Locust support:

### Directory Structure

```
templates/benchmarks/locust/
├── benchmark-job.yaml
└── cleanup-job.yaml
```

### benchmark-job.yaml

```yaml
{{- if and (eq .Values.jobType "benchmark") (eq .Values.benchmarkTool "locust") }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "llm-d-bench.benchmarkJobName" . }}
  namespace: {{ include "llm-d-bench.namespace" . }}
  labels:
    {{- include "llm-d-bench.labels" . | nindent 4 }}
    job-type: benchmark
    benchmark-tool: locust
spec:
  template:
    spec:
      containers:
      - name: locust-container
        image: locustio/locust:latest
        command: ["/bin/bash"]
        args:
          - -c
          - |
            export RUN_DIR="{{ .Values.pvc.mountPath }}/run_$(date +%s)"
            mkdir -p $${RUN_DIR}

            locust \
              --host {{ .Values.benchmark.targetUrl }} \
              --users {{ .Values.benchmark.parameters.users }} \
              --spawn-rate {{ .Values.benchmark.parameters.spawnRate }} \
              --run-time {{ .Values.benchmark.parameters.duration }}s \
              --headless \
              --only-summary \
              --csv $${RUN_DIR}/results
        volumeMounts:
        - name: results
          mountPath: {{ .Values.pvc.mountPath }}
      volumes:
      - name: results
        persistentVolumeClaim:
          claimName: {{ include "llm-d-bench.pvcName" . }}
      restartPolicy: Never
{{- end }}
```

### values file (examples/locust-example.yaml)

```yaml
benchmarkTool: locust
jobType: benchmark

benchmark:
  name: locust-test
  targetUrl: http://llm-service:8080

  image:
    repository: locustio/locust
    tag: latest

  parameters:
    users: 100
    spawnRate: 10
    duration: 300

pvc:
  create: false
  name: llm-d-bench-pvc
```

## Validation

After adding a new benchmark tool:

1. **Lint**: `helm lint ./llm-d-bench`
2. **Template**: `helm template test ./llm-d-bench -f your-example.yaml`
3. **Dry-run**: `helm install test ./llm-d-bench -f your-example.yaml --dry-run`
4. **Deploy**: `helm install test ./llm-d-bench -f your-example.yaml`
5. **Verify**: `oc get jobs` and `oc logs job/your-job`

## Common Patterns

### Pattern 1: Multiple Benchmark Runs

```yaml
# Run the same benchmark with different tools
helm install guidellm-test ./llm-d-bench \
  --set benchmarkTool=guidellm \
  -f benchmark-config.yaml

helm install locust-test ./llm-d-bench \
  --set benchmarkTool=locust \
  -f benchmark-config.yaml
```

### Pattern 2: Tool-Specific Configuration

```yaml
# In values.yaml, use nested config per tool
guidellm:
  rates: "1,50,100,200"
  maxSeconds: 600

locust:
  users: 100
  spawnRate: 10
  duration: 300
```

Access in templates:
```yaml
{{- if eq .Values.benchmarkTool "guidellm" }}
--rate={{ .Values.guidellm.rates }}
{{- else if eq .Values.benchmarkTool "locust" }}
--users {{ .Values.locust.users }}
{{- end }}
```

## Contributing

When contributing a new benchmark tool:

1. Follow the structure above
2. Include example values file
3. Add documentation
4. Test thoroughly
5. Submit PR with:
   - Templates
   - Examples
   - Documentation updates
   - Test results

For questions or help, open an issue in the repository.
