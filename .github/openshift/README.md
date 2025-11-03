# OpenShift Authentication Configuration for GitHub Actions

This directory contains OpenShift RBAC configurations for GitHub Actions workflows.

## ServiceAccount Authentication

### Prerequisites

- Access to OpenShift cluster with admin privileges
- `oc` CLI installed and configured
- Access to the `llm-d-inference-scheduling` namespace

### Step 1: Apply RBAC Configurations

Apply the ServiceAccount, Role, and RoleBinding:

```
oc apply -f .github/openshift/serviceaccount.yaml
oc apply -f .github/openshift/role.yaml
oc apply -f .github/openshift/rolebinding.yaml
```

### Step 2: Get the ServiceAccount Token

#### For OpenShift 4.11+

Create a long-lived token (expires in 1 year):

```
oc create token github-actions -n llm-d-inference-scheduling --duration=8760h
```

### Step 3: Configure GitHub Secrets

Add the following secrets to your GitHub repository:

1. **OPENSHIFT_TOKEN**: The token obtained in Step 2
2. **OPENSHIFT_SERVER_URL**: Your OpenShift API server URL (e.g., `https://api.your-cluster.example.com:6443`)
3. **OPENSHIFT_CA_CERT**: The CA certificate for your cluster

To get the CA certificate:

```bash
oc config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d
```