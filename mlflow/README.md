# MLflow Deployment for OpenShift

This directory contains Kubernetes manifests for deploying MLflow on OpenShift with PostgreSQL backend and AWS S3 artifact storage.

## Prerequisites

- OpenShift cluster with admin access
- `oc` CLI tool installed and configured
- Sufficient storage provisioner for PVC (10Gi for PostgreSQL)
- AWS S3 bucket for artifact storage
- AWS IAM credentials with read/write access to the S3 bucket (see [AWS_IAM_POLICY.md](AWS_IAM_POLICY.md) for required permissions)

## Quick Start

### 1. Update Secrets

Before deploying, update the credentials in `01-namespace.yaml`:

```yaml
# PostgreSQL credentials
POSTGRES_PASSWORD: mlflow-db-password-change-me

# AWS S3 credentials
access-key: YOUR_AWS_ACCESS_KEY_ID
secret-key: YOUR_AWS_SECRET_ACCESS_KEY
bucket-name: your-s3-bucket-name
region: us-east-1  # Change to your bucket's region

# MLflow admin credentials
admin-password: mlflow-admin-password-change-me
```

### 2. Deploy All Components

```
# Deploy in order
oc apply -f 01-namespace.yaml
oc apply -f 02-postgresql.yaml
oc apply -f 04-mlflow.yaml
oc apply -f 05-route.yaml
```

### 3. Verify Deployment

Check that all pods are running:

```
oc get pods -n mlflow
```

Expected output:
```
NAME                            READY   STATUS    RESTARTS   AGE
postgresql-xxx                  1/1     Running   0          5m
mlflow-server-xxx               1/1     Running   0          3m
```

### 4. Access MLflow

Get the MLflow route URL:

```
oc get route mlflow -n mlflow -o jsonpath='{.spec.host}'
```

Access MLflow in your browser using the URL above. Login with:
- **Username**: `admin` (or the value you set in `01-namespace.yaml`)
- **Password**: The password you set in `01-namespace.yaml`

## Using MLflow

### Python Client Example

```python
import mlflow
import os

mlflow.set_tracking_uri("https://mlflow-mlflow.apps.your-cluster.com")

os.environ["MLFLOW_TRACKING_USERNAME"] = "admin"
os.environ["MLFLOW_TRACKING_PASSWORD"] = "your-password"

with mlflow.start_run():
    mlflow.log_param("param1", 5)
    mlflow.log_metric("metric1", 0.85)
    mlflow.log_artifact("model.pkl")
```

### CLI Example

```bash
export MLFLOW_TRACKING_URI=https://mlflow-mlflow.apps.your-cluster.com
export MLFLOW_TRACKING_USERNAME=admin
export MLFLOW_TRACKING_PASSWORD=your-password

mlflow experiments list
```
