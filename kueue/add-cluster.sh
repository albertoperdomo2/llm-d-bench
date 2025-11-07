#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

CLUSTER_NAME=$1
KUBECONFIG_PATH=$2
CLUSTER_QUEUE_NAME=${CLUSTER_QUEUE_NAME:-"multi-cluster-queue"}
NAMESPACE=${NAMESPACE}

if [ -z "$CLUSTER_NAME" ] || [ -z "$KUBECONFIG_PATH" ]; then
    echo "Usage: $0 <cluster-name> <kubeconfig-path>"
    echo "Example: $0 cluster-gpu-west ~/.kube/west-cluster-config"
    echo ""
    echo "Environment variables (from .env or shell):"
    echo "  CLUSTER_QUEUE_NAME - ClusterQueue name (default: multi-cluster-queue)"
    echo "  NAMESPACE - Benchmark namespace (default: llm-d-inference-scheduling)"
    exit 1
fi

if [ ! -f "$KUBECONFIG_PATH" ]; then
    echo "Error: kubeconfig file not found at $KUBECONFIG_PATH"
    exit 1
fi

echo "Adding cluster: $CLUSTER_NAME"
echo "ClusterQueue: $CLUSTER_QUEUE_NAME"
echo "Namespace: $NAMESPACE"

echo "[1/6] Setting up worker cluster resources..."
export NAMESPACE CLUSTER_QUEUE_NAME
envsubst < "${SCRIPT_DIR}/00-worker-cluster-setup.yaml" | \
    oc --kubeconfig="$KUBECONFIG_PATH" apply -f -

echo "[2/6] Creating kubeconfig secret on management cluster..."
oc create secret generic ${CLUSTER_NAME}-kubeconfig \
    --from-file=kubeconfig=$KUBECONFIG_PATH \
    -n kueue-system \
    --dry-run=client -o yaml | oc apply -f -

echo "[3/6] Creating MultiKueueCluster resource on management cluster..."
cat <<EOF | oc apply -f -
apiVersion: kueue.x-k8s.io/v1alpha1
kind: MultiKueueCluster
metadata:
  name: $CLUSTER_NAME
spec:
  kubeConfig:
    location: Secret
    locationName: ${CLUSTER_NAME}-kubeconfig
EOF

echo "[4/6] Creating AdmissionCheck on management cluster..."
cat <<EOF | oc apply -f -
apiVersion: kueue.x-k8s.io/v1beta1
kind: AdmissionCheck
metadata:
  name: $CLUSTER_NAME
spec:
  controllerName: kueue.x-k8s.io/multikueue
  parameters:
    apiGroup: kueue.x-k8s.io/v1alpha1
    kind: MultiKueueCluster
    name: $CLUSTER_NAME
EOF

echo "[5/6] Checking ClusterQueue on management cluster..."
if ! oc get clusterqueue $CLUSTER_QUEUE_NAME &>/dev/null; then
    echo "ClusterQueue $CLUSTER_QUEUE_NAME doesn't exist. Creating..."
    cat <<EOF | oc apply -f -
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: $CLUSTER_QUEUE_NAME
spec:
  namespaceSelector: {}
  admissionChecks:
    - $CLUSTER_NAME
  resourceGroups:
    - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
      flavors:
        - name: default-flavor
          resources:
            - name: "cpu"
              nominalQuota: 1000
            - name: "memory"
              nominalQuota: 1000Gi
            - name: "nvidia.com/gpu"
              nominalQuota: 100
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: default-flavor
EOF
else
    echo "ClusterQueue $CLUSTER_QUEUE_NAME exists. Adding admission check..."

    # Check if admission check already exists in the ClusterQueue
    if oc get clusterqueue $CLUSTER_QUEUE_NAME -o json | jq -e ".spec.admissionChecks // [] | any(. == \"$CLUSTER_NAME\")" > /dev/null 2>&1; then
        echo "AdmissionCheck $CLUSTER_NAME already in ClusterQueue. Skipping..."
    else
        oc patch clusterqueue $CLUSTER_QUEUE_NAME --type='json' -p="[{\"op\":\"add\",\"path\":\"/spec/admissionChecks/-\",\"value\":\"$CLUSTER_NAME\"}]"
        echo "Added $CLUSTER_NAME to ClusterQueue admissionChecks"
    fi
fi

# 6. Check if LocalQueue exists on management cluster, create if not
echo "[6/6] Checking LocalQueue on management cluster..."
if ! oc get localqueue guidellm-jobs -n $NAMESPACE &>/dev/null; then
    echo "Creating LocalQueue guidellm-jobs..."
    cat <<EOF | oc apply -f -
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: guidellm-jobs
  namespace: $NAMESPACE
spec:
  clusterQueue: $CLUSTER_QUEUE_NAME
EOF
else
    echo "LocalQueue guidellm-jobs already exists"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Cluster $CLUSTER_NAME fully configured!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Your colleagues can now use it in experiments:"
echo ""
echo "  kueue:"
echo "    enabled: true"
echo "    multiCluster:"
echo "      enabled: true"
echo "      targetCluster: $CLUSTER_NAME"
echo ""
echo "Or via PR comment:"
echo "  /benchmark my-experiment"
echo "  kueue.enabled=true"
echo "  kueue.multiCluster.enabled=true"
echo "  kueue.multiCluster.targetCluster=$CLUSTER_NAME"
echo ""
