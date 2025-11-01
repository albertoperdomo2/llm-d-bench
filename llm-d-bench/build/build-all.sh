#!/bin/bash
# Build container images directly in OpenShift using BuildConfig
# Usage: ./build-all.sh [namespace] [tag]

set -euo pipefail

NAMESPACE="${1:-llm-d-inference-scheduling}"
TAG="${2:-latest}"
BENCHMARK_IMAGE="guidellm-runner"
MONITORING_IMAGE="vllm-metrics-collector"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

if ! command -v oc &> /dev/null; then
    log_error "OpenShift CLI (oc) not found. Please install it."
    exit 1
fi

if ! oc whoami &> /dev/null; then
    log_error "Not logged in to OpenShift. Please run 'oc login' first."
    exit 1
fi

log_info "Starting OpenShift build process..."
log_info "Namespace: ${NAMESPACE}"
log_info "Tag: ${TAG}"

log_info "Switching to namespace: ${NAMESPACE}"
oc project ${NAMESPACE} || {
    log_error "Failed to switch to namespace ${NAMESPACE}"
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

create_or_update_buildconfig() {
    local name=$1
    local dockerfile_path=$2
    local context_dir=$3

    log_info "Creating/updating BuildConfig for ${name}..."

    # Delete existing BuildConfig to ensure clean state
    if oc get buildconfig ${name} &> /dev/null; then
        log_info "Deleting existing BuildConfig ${name}..."
        oc delete buildconfig ${name}
    fi

    cat <<EOF | oc apply -f -
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
spec:
  output:
    to:
      kind: ImageStreamTag
      name: ${name}:${TAG}
  source:
    type: Binary
    binary: {}
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: ${dockerfile_path}
  triggers: []
EOF

    if [ $? -eq 0 ]; then
        log_info "✓ BuildConfig ${name} created/updated"
    else
        log_error "✗ Failed to create/update BuildConfig ${name}"
        return 1
    fi
}

create_imagestream() {
    local name=$1
    
    if ! oc get imagestream ${name} &> /dev/null; then
        log_info "Creating ImageStream for ${name}..."
        oc create imagestream ${name}
        if [ $? -eq 0 ]; then
            log_info "✓ ImageStream ${name} created"
        else
            log_error "✗ Failed to create ImageStream ${name}"
            return 1
        fi
    else
        log_info "ImageStream ${name} already exists"
    fi
}

start_build() {
    local name=$1
    local context_path=$2
    
    log_info "Starting build for ${name} from ${context_path}..."
    
    # Start the build with binary source
    BUILD_NAME=$(oc start-build ${name} --from-dir="${context_path}" --follow 2>&1 | tee /dev/tty | grep "build.build.openshift.io/" | awk '{print $1}' | cut -d'/' -f2)
    
    if [ $? -eq 0 ]; then
        log_info "✓ Build ${name} completed successfully"
        
        # Tag the build
        log_info "Tagging ${name}:${TAG}"
        oc tag ${name}:${TAG} ${name}:latest
        
        return 0
    else
        log_error "✗ Build ${name} failed"
        return 1
    fi
}

log_info "=== Building Benchmark Container ==="
create_imagestream ${BENCHMARK_IMAGE} || exit 1
create_or_update_buildconfig ${BENCHMARK_IMAGE} "Dockerfile" "." || exit 1
start_build ${BENCHMARK_IMAGE} "${SCRIPT_DIR}" || exit 1

log_info "=== Building Monitoring Sidecar ==="
create_imagestream ${MONITORING_IMAGE} || exit 1
create_or_update_buildconfig ${MONITORING_IMAGE} "Dockerfile" "." || exit 1
start_build ${MONITORING_IMAGE} "${SCRIPT_DIR}/monitoring" || exit 1

REGISTRY=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}' 2>/dev/null)
if [ -z "$REGISTRY" ]; then
    REGISTRY="image-registry.openshift-image-registry.svc:5000"
    log_warn "External registry route not found, using internal registry: ${REGISTRY}"
fi

BENCHMARK_FULL_IMAGE="${REGISTRY}/${NAMESPACE}/${BENCHMARK_IMAGE}:${TAG}"
MONITORING_FULL_IMAGE="${REGISTRY}/${NAMESPACE}/${MONITORING_IMAGE}:${TAG}"

log_info "Build summary:"
echo ""
echo "  Benchmark Image: ${BENCHMARK_FULL_IMAGE}"
echo "  Monitoring Image: ${MONITORING_FULL_IMAGE}"
echo ""
log_info "Images are now available in OpenShift internal registry"
echo ""
log_info "Update your Helm values.yaml with these images:"
echo ""
echo "  benchmark:"
echo "    image:"
echo "      repository: ${BENCHMARK_IMAGE}"
echo "      tag: ${TAG}"
echo "      pullPolicy: Always"
echo ""
echo "  monitoring:"
echo "    sidecar:"
echo "      image:"
echo "        repository: ${MONITORING_IMAGE}"
echo "        tag: ${TAG}"
echo "        pullPolicy: Always"
echo ""
log_info "Note: When using images from the same namespace, you can use just the image name"
log_info "without the full registry path."
echo ""

log_info "Image details:"
echo ""
oc describe imagestream ${BENCHMARK_IMAGE} | grep -A 2 "${TAG}"
oc describe imagestream ${MONITORING_IMAGE} | grep -A 2 "${TAG}"
echo ""

# Clean up completed builds to save space
log_info "=== Cleaning up completed builds ==="

cleanup_builds() {
    local buildconfig_name=$1

    log_info "Cleaning up builds for ${buildconfig_name}..."

    # Get all completed builds for this buildconfig
    BUILDS=$(oc get builds -l buildconfig=${buildconfig_name} -o name 2>/dev/null)

    if [ -z "$BUILDS" ]; then
        log_info "No builds found for ${buildconfig_name}"
        return 0
    fi

    # Count total builds
    TOTAL_BUILDS=$(echo "$BUILDS" | wc -l)
    log_info "Found ${TOTAL_BUILDS} build(s) for ${buildconfig_name}"

    # Delete all builds for this buildconfig
    for BUILD in $BUILDS; do
        BUILD_NAME=$(echo $BUILD | cut -d'/' -f2)
        log_info "Deleting build: ${BUILD_NAME}"
        oc delete build ${BUILD_NAME} --ignore-not-found=true
    done

    log_info "✓ Cleaned up builds for ${buildconfig_name}"
}

cleanup_builds ${BENCHMARK_IMAGE}
cleanup_builds ${MONITORING_IMAGE}

log_info "✓ Build cleanup completed"
echo ""

log_info "Done!"
log_info "To rebuild images, simply run this script again."
