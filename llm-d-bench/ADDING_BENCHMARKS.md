# Adding New Benchmark Tools

Guide for adding support for new benchmark tools to the chart.

## Directory Structure

```
templates/benchmarks/
├── _common/          # Shared templates (PVC)
├── guidellm/         # GuideLLM (default)
└── your-tool/        # Your new tool
```

## Steps

### 1. Create Tool Directory

```bash
mkdir -p templates/benchmarks/your-tool
```

### 2. Create Benchmark Job Template

`templates/benchmarks/your-tool/benchmark-job.yaml`:

```yaml
{{- if and (eq .Values.jobType "benchmark") (eq .Values.benchmarkTool "your-tool") }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Values.benchmark.name }}
  namespace: {{ .Values.namespace }}
  labels:
    app: llm-d-bench
    job-type: benchmark
spec:
  template:
    spec:
      containers:
      - name: benchmark
        image: "{{ .Values.benchmark.image.repository }}:{{ .Values.benchmark.image.tag }}"
        command: ["/bin/bash"]
        args:
          - -c
          - |
            export RUN_DIR="/results/run_$(date +%s)"
            mkdir -p ${RUN_DIR}

            your-tool run \
              --target {{ .Values.benchmark.target }} \
              --output ${RUN_DIR}/output.json
        volumeMounts:
        - name: results
          mountPath: /results
        resources:
          requests:
            memory: "2Gi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "1000m"
      volumes:
      - name: results
        persistentVolumeClaim:
          claimName: {{ .Values.pvc.name }}
      restartPolicy: Never
      {{- if .Values.benchmark.nodeSelector }}
      nodeSelector:
        {{- toYaml .Values.benchmark.nodeSelector | nindent 8 }}
      {{- end }}
      {{- if .Values.benchmark.affinity }}
      affinity:
        {{- toYaml .Values.benchmark.affinity | nindent 8 }}
      {{- end }}
  backoffLimit: 2
{{- end }}
```

### 3. Add Values Configuration

In `values.yaml`:

```yaml
benchmarkTool: your-tool

benchmark:
  name: your-tool-test
  image:
    repository: your-registry/your-tool
    tag: latest
  target: ""
  # Add tool-specific parameters
```

### 4. Create Example File

`examples/your-tool-example.yaml`:

```yaml
benchmarkTool: your-tool
jobType: benchmark

benchmark:
  name: test
  target: http://service:8080
  image:
    repository: your-registry/your-tool
    tag: latest

pvc:
  create: false
  name: llm-d-bench-pvc
```

### 5. Test

```bash
helm lint ./llm-d-bench
helm template test ./llm-d-bench -f examples/your-tool-example.yaml
helm install test ./llm-d-bench -f examples/your-tool-example.yaml -n keda
```

## Key Points

- Use conditional rendering: `{{- if and (eq .Values.jobType "benchmark") (eq .Values.benchmarkTool "your-tool") }}`
- Save results to `/results/run_$(date +%s)/`
- Include nodeSelector and affinity support for scheduling control
- Add resource limits
- Use the shared PVC from `_common/pvc.yaml`

## Cleanup Job (Optional)

`templates/benchmarks/your-tool/cleanup-job.yaml`:

```yaml
{{- if and (eq .Values.jobType "cleanup") (eq .Values.benchmarkTool "your-tool") }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Values.cleanup.name }}
  namespace: {{ .Values.namespace }}
spec:
  template:
    spec:
      containers:
      - name: cleanup
        image: registry.access.redhat.com/ubi9-micro:latest
        command: ["/bin/bash", "-c", "rm -rf /results/run_*"]
        volumeMounts:
        - name: results
          mountPath: /results
      volumes:
      - name: results
        persistentVolumeClaim:
          claimName: {{ .Values.pvc.name }}
      restartPolicy: Never
{{- end }}
```
