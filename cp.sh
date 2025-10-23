#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

PVC_NAME="guidellm-pvc"
NAMESPACE="llm-d-inference-scheduler"
PVC_MOUNT_PATH="/results"
LOCAL_DIR="./results"

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <remote-dir> <file1> [file2] [file3] ..."
    echo "Example: $0 run_1760514146 file1.txt file2.log /path/dir/*"
    exit 1
fi

trap 'echo "Cleaning up..."; oc delete pod pvc-copy-pod -n $NAMESPACE --ignore-not-found=true 2>/dev/null || true' EXIT INT TERM

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

echo "Copying files..."
for file in "${FILES[@]}"; do
    for attempt in {1..3}; do
        echo "  Copying: $file (attempt: $attempt/3)"
        if rsync --rsh='oc rsh' --append pvc-copy-pod:$PVC_MOUNT_PATH/$REMOTE_DIR/$file "$LOCAL_DIR/$REMOTE_DIR"; then
            break
        fi
        sleep 5
    done
done

echo "Done! Files copied to $LOCAL_DIR"
