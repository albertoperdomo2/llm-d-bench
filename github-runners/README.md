# Self-Hosted GitHub Actions Runners on OpenShift

Deploy self-hosted GitHub Actions runners on OpenShift using StatefulSets.

## Prerequisites

- OpenShift cluster with cluster-admin access
- `oc` CLI tool installed and configured
- GitHub Personal Access Token (PAT)

## Quick Start

### 1. Create GitHub Personal Access Token

Create a PAT at: https://github.com/settings/tokens/new

Required scopes:
- **Repository runners**: `repo` (Full control of private repositories)
- **Organization runners**: `repo` + `admin:org` (Full control of orgs and teams)

### 2. Configure

Edit `01-namespace.yaml` and set your GitHub token:

```yaml
stringData:
  github_token: "YOUR_GITHUB_PAT_HERE"
```

Edit `03-runner-deployment.yaml` and configure your GitHub organization/repository:

```yaml
env:
  - name: GITHUB_OWNER
    value: "your-org-or-username"
  - name: GITHUB_REPOSITORY
    value: "your-repo"  # Leave empty ("") for organization-level runners
```

### 3. Deploy

```bash
# Deploy all required resources
oc apply -f 01-namespace.yaml
oc apply -f 02-controller-rbac.yaml
oc apply -f 03-runner-deployment.yaml
oc apply -f 05-openshift-scc.yaml

# Optional: Deploy HPA for auto-scaling
oc apply -f 05-hpa.yaml
```

### 4. Verify

```bash
# Check pods
oc get pods -n github-runners

# Check logs
oc logs -f github-runner-0 -n github-runners -c runner

# View runners in GitHub
# - Organization: https://github.com/YOUR_ORG/settings/actions/runners
# - Repository: https://github.com/YOUR_ORG/YOUR_REPO/settings/actions/runners
```

You should see output like:
```
Connected to GitHub
Listening for Jobs
```

## Configuration

### Scale Runners

```bash
# Manual scaling
oc scale statefulset github-runner -n github-runners --replicas=5

# Or edit the StatefulSet
oc edit statefulset github-runner -n github-runners
```

### Runner Labels

Customize runner labels in `03-runner-deployment.yaml`:

```yaml
- name: RUNNER_LABELS
  value: "openshift,self-hosted,linux,x64,gpu"
```

Use in workflows:

```yaml
jobs:
  build:
    runs-on: [self-hosted, openshift]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on self-hosted runner"
```

### Runner Timeout

Adjust job timeout (default: 12 hours) in `03-runner-deployment.yaml`:

```yaml
- name: RUNNER_JOB_TIMEOUT
  value: "43200000"  # milliseconds (12 hours)
```

Common values:
- 1 hour: `3600000`
- 6 hours: `21600000`
- 12 hours: `43200000`
- 24 hours: `86400000`

### Runner Groups

For organization runners, assign to a specific runner group:

```yaml
- name: RUNNER_GROUP
  value: "my-runner-group"
```

### Resource Limits

Adjust CPU/memory in `03-runner-deployment.yaml`:

```yaml
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 2000m
    memory: 4Gi
```

### How It Works

1. Runner pods start and execute the startup script
2. Script obtains a registration token from GitHub API using the PAT
3. Runner registers with GitHub and starts listening for jobs
4. When a workflow uses `runs-on: [self-hosted, openshift]`, GitHub assigns the job to an available runner
5. Runner executes the workflow and reports results back to GitHub
6. On pod termination, the runner is automatically removed from GitHub
