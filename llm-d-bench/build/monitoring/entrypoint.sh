#!/bin/bash
# Monitoring Sidecar Entrypoint
# Handles lifecycle coordination with benchmark container

set -euo pipefail

# Configuration from environment variables
THANOS_URL="${THANOS_URL:-https://thanos-querier.openshift-monitoring.svc.cluster.local:9091}"
RESULTS_BASE_DIR="${RESULTS_BASE_DIR:-/results}"
COLLECTION_INTERVAL="${COLLECTION_INTERVAL:-10}"
METRICS="${METRICS:-}"
LABELS="${LABELS:-}"
COLLECT_NODE_METRICS="${COLLECT_NODE_METRICS:-true}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
TOKEN_FILE="${TOKEN_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/token}"

# Shared state directory for container coordination
STATE_DIR="/tmp/monitoring"
HEALTHY_FILE="${STATE_DIR}/.healthy"
START_SIGNAL="${STATE_DIR}/.start_collection"
STOP_SIGNAL="${STATE_DIR}/.stop_collection"

# Initialize
mkdir -p "${STATE_DIR}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [MONITORING] $*"
}

cleanup() {
    log "Received termination signal, cleaning up..."
    rm -f "${HEALTHY_FILE}"

    # Kill metrics collector if running
    if [ -n "${COLLECTOR_PID:-}" ]; then
        log "Stopping metrics collector (PID: ${COLLECTOR_PID})..."
        kill -TERM "${COLLECTOR_PID}" 2>/dev/null || true
        wait "${COLLECTOR_PID}" 2>/dev/null || true
    fi

    # Generate visualization if data exists
    if [ -n "${OUTPUT_DIR:-}" ] && [ -f "${OUTPUT_DIR}"/metrics_*.csv ]; then
        log "Generating metrics visualization..."
        /usr/local/bin/plot_vllm_metrics.py "${OUTPUT_DIR}"/metrics_*.csv || log "Warning: Visualization generation failed"
    fi

    log "Cleanup complete"
    exit 0
}

# Setup signal handlers
trap cleanup SIGTERM SIGINT

log "Monitoring sidecar starting..."
log "Thanos URL: ${THANOS_URL}"
log "Results base directory: ${RESULTS_BASE_DIR}"
log "Collection interval: ${COLLECTION_INTERVAL}s"

# Mark as healthy
touch "${HEALTHY_FILE}"

# Wait for start signal from benchmark container
log "Waiting for benchmark to start (looking for ${START_SIGNAL})..."
while [ ! -f "${START_SIGNAL}" ]; do
    sleep 1

    # Check if we should exit (stop signal without start means benchmark failed)
    if [ -f "${STOP_SIGNAL}" ]; then
        log "Received stop signal before start - benchmark may have failed. Exiting."
        exit 0
    fi
done

log "Start signal received, finding run directory..."

# Find the most recent run directory
RUN_DIR=$(find "${RESULTS_BASE_DIR}" -maxdepth 1 -type d -name "run_*" | sort -r | head -n 1)
if [ -z "${RUN_DIR}" ]; then
    log "ERROR: No run directory found in ${RESULTS_BASE_DIR}"
    exit 1
fi

OUTPUT_DIR="${RUN_DIR}/metrics"
mkdir -p "${OUTPUT_DIR}"
log "Using run directory: ${RUN_DIR}"
log "Metrics output directory: ${OUTPUT_DIR}"

# Build collector command
COLLECTOR_CMD="/usr/local/bin/vllm_metrics_collector.py \
    --thanos-url=\"${THANOS_URL}\" \
    --output-dir=\"${OUTPUT_DIR}\" \
    --interval=${COLLECTION_INTERVAL} \
    --log-level=${LOG_LEVEL} \
    --token-file=\"${TOKEN_FILE}\""

# Add optional metrics filter
if [ -n "${METRICS}" ]; then
    COLLECTOR_CMD="${COLLECTOR_CMD} --metrics=\"${METRICS}\""
fi

# Add optional label filters
if [ -n "${LABELS}" ]; then
    COLLECTOR_CMD="${COLLECTOR_CMD} --labels=\"${LABELS}\""
fi

# Add node metrics flag
if [ "${COLLECT_NODE_METRICS}" != "true" ]; then
    COLLECTOR_CMD="${COLLECTOR_CMD} --no-node-metrics"
fi

# Start metrics collector in background
log "Starting metrics collector..."
eval "${COLLECTOR_CMD}" &
COLLECTOR_PID=$!
log "Metrics collector started with PID: ${COLLECTOR_PID}"

# Monitor for stop signal or collector exit
while true; do
    # Check if collector process is still running
    if ! kill -0 "${COLLECTOR_PID}" 2>/dev/null; then
        log "Metrics collector process exited unexpectedly"
        break
    fi

    # Check for stop signal
    if [ -f "${STOP_SIGNAL}" ]; then
        log "Stop signal received from benchmark container"
        break
    fi

    sleep 2
done

# Graceful shutdown
log "Initiating graceful shutdown..."
if kill -0 "${COLLECTOR_PID}" 2>/dev/null; then
    log "Sending SIGTERM to metrics collector..."
    kill -TERM "${COLLECTOR_PID}"

    # Wait up to 30 seconds for graceful shutdown
    for i in {1..30}; do
        if ! kill -0 "${COLLECTOR_PID}" 2>/dev/null; then
            log "Metrics collector stopped gracefully"
            break
        fi
        sleep 1
    done

    # Force kill if still running
    if kill -0 "${COLLECTOR_PID}" 2>/dev/null; then
        log "Force killing metrics collector..."
        kill -9 "${COLLECTOR_PID}" || true
    fi
fi

# Generate visualization
log "Generating metrics visualization..."
if [ -f "${OUTPUT_DIR}"/metrics_*.csv ]; then
    /usr/local/bin/plot_vllm_metrics.py "${OUTPUT_DIR}"/metrics_*.csv || log "Warning: Visualization generation failed"
else
    log "No metrics data found for visualization"
fi

log "Monitoring sidecar completed successfully"
rm -f "${HEALTHY_FILE}"
exit 0
