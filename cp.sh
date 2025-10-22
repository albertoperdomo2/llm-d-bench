#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

PVC_NAME="guidellm-pvc"
NAMESPACE="llm-d-inference-scheduler"
PVC_MOUNT_PATH="/results"

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <local-dir> <remote-dir> <file1> [file2] [file3] ..."
    echo "Example: $0 ./results_dir run_1760514146 file1.txt file2.log /path/dir/*"
    exit 1
fi

trap 'echo "Cleaning up..."; oc delete pod pvc-copy-pod -n $NAMESPACE --ignore-not-found=true 2>/dev/null || true' EXIT INT TERM

LOCAL_DIR="$1"
shift
REMOTE_DIR="$1"
shift
FILES=("$@")

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
    image: busybox
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
oc wait --for=condition=Ready pod/pvc-copy-pod -n $NAMESPACE --timeout=60s

echo "Copying files..."
for file in "${FILES[@]}"; do
    for attempt in {1..3}; do
        echo "  Copying: $file (attempt: $attempt/3)"
        if oc cp $NAMESPACE/pvc-copy-pod:$PVC_MOUNT_PATH/$REMOTE_DIR/$file "$LOCAL_DIR/$(basename $file)" -c copier; then
            break
        fi
        sleep 5
    done
done

echo "Done! Files copied to $LOCAL_DIR"
