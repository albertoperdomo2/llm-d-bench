#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

PVC_NAME="guidellm-pvc"
NAMESPACE="llm-d-inference-scheduler"
PVC_MOUNT_PATH="/results"
LOCAL_DIR="./results"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <remote-dir>"
    echo "Example: $0 run_1760514146"
    exit 1
fi

trap 'echo "Cleaning up..."; oc delete pod pvc-copy-pod -n $NAMESPACE --ignore-not-found=true 2>/dev/null || true' EXIT INT TERM

REMOTE_DIR="$1"

mkdir -p "$LOCAL_DIR"

echo "Creating temporary pod to access PVC..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pvc-copy-pod
  namespace: $NAMESPACE
spec:
  containers:
  - name: copier
    image: instrumentisto/rsync-ssh:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: pvc-storage
      mountPath: $PVC_MOUNT_PATH
  volumes:
  - name: pvc-storage
    persistentVolumeClaim:
      claimName: $PVC_NAME
  restartPolicy: Never
EOF

echo "Waiting for pod to be ready..."
oc wait --for=condition=Ready pod/pvc-copy-pod -n $NAMESPACE --timeout=180s

echo "Syncing directory: $REMOTE_DIR"
mkdir -p "$LOCAL_DIR/$REMOTE_DIR"

for attempt in {1..3}; do
    echo "  Syncing directory (attempt: $attempt/3)"
    if rsync -avz --rsh='oc rsh' pvc-copy-pod:$PVC_MOUNT_PATH/$REMOTE_DIR/ "$LOCAL_DIR/$REMOTE_DIR/"; then
        echo "Sync completed successfully!"
        break
    fi
    echo "  Sync failed, retrying in 5 seconds..."
    sleep 5
done

echo "Done! Directory synced to $LOCAL_DIR/$REMOTE_DIR"
