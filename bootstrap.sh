#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_header() {
    echo -e "\n${BOLD}${CYAN}===================================================================${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}===================================================================${NC}\n"
}

log_step() {
    echo -e "${BLUE}▶${NC} ${BOLD}$1${NC}"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_info() {
    echo -e "${CYAN}ℹ${NC} $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
BUILD_DIR="${SCRIPT_DIR}/build"
MLFLOW_DIR="${SCRIPT_DIR}/mlflow"
GITHUB_RUNNERS_DIR="${SCRIPT_DIR}/github-runners"
KUEUE_DIR="${SCRIPT_DIR}/kueue"

# Deployment flags
DEPLOY_REFLECTOR="${DEPLOY_REFLECTOR:-true}"
DEPLOY_KUEUE="${DEPLOY_KUEUE:-true}"
DEPLOY_MLFLOW="${DEPLOY_MLFLOW:-true}"
DEPLOY_GITHUB_RUNNERS="${DEPLOY_GITHUB_RUNNERS:-true}"
BUILD_IMAGE="${BUILD_IMAGE:-true}"
SKIP_VALIDATION="${SKIP_VALIDATION:-false}"
DRY_RUN="${DRY_RUN:-false}"
DRY_RUN_DIR="${SCRIPT_DIR}/dry-run-output"

check_prerequisites() {
    log_header "Checking Prerequisites"

    local all_good=true

    log_step "Checking oc CLI..."
    if command -v oc &> /dev/null; then
        OC_VERSION=$(oc version --client 2>/dev/null | head -n1 || echo "unknown")
        log_success "oc CLI found: $OC_VERSION"
    else
        log_error "oc CLI not found. Please install OpenShift CLI."
        all_good=false
    fi

    if [[ "$DEPLOY_REFLECTOR" == "true" ]] || [[ "$DRY_RUN" == "true" ]]; then
        log_step "Checking helm CLI..."
        if command -v helm &> /dev/null; then
            HELM_VERSION=$(helm version --short 2>/dev/null || echo "unknown")
            log_success "helm CLI found: $HELM_VERSION"
        else
            log_error "helm CLI not found. Please install Helm."
            all_good=false
        fi
    fi

    log_step "Checking cluster connection..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Dry-run mode: skipping cluster connection check"
    elif oc whoami &> /dev/null; then
        CLUSTER_USER=$(oc whoami)
        CLUSTER_SERVER=$(oc whoami --show-server)
        log_success "Connected to cluster as: $CLUSTER_USER"
        log_info "Cluster: $CLUSTER_SERVER"
    else
        log_error "Not connected to an OpenShift cluster. Run 'oc login' first."
        all_good=false
    fi

    if [[ "$SKIP_VALIDATION" != "true" ]]; then
        log_step "Checking .env file..."
        if [[ -f "$ENV_FILE" ]]; then
            log_success "Found .env file"
        else
            log_error ".env file not found at: $ENV_FILE"
            log_info "Create a .env file based on .env.example"
            all_good=false
        fi
    fi

    if [[ "$all_good" != "true" ]]; then
        log_error "Prerequisites check failed. Please fix the issues above."
        exit 1
    fi

    echo ""
}

load_env_file() {
    if [[ -f "$ENV_FILE" ]]; then
        log_step "Loading environment variables from .env..."
        set -a
        source "$ENV_FILE"
        set +a
        log_success "Environment variables loaded"
    else
        log_warning "No .env file found, skipping..."
    fi
}

setup_dry_run() {
    if [[ "$DRY_RUN" != "true" ]]; then
        return 0
    fi

    log_header "Setting up Dry-Run Mode"

    log_step "Creating dry-run output directory..."
    rm -rf "$DRY_RUN_DIR"
    mkdir -p "$DRY_RUN_DIR"/{reflector,kueue,mlflow,github-runners,build,namespace}
    log_success "Created directory: $DRY_RUN_DIR"

    echo -e "\n${CYAN}${BOLD}Dry-run mode enabled${NC}"
    echo -e "Manifests will be generated and saved to: ${CYAN}$DRY_RUN_DIR${NC}"
    echo -e "No actual deployment will occur.\n"
}

deploy_namespace_secrets() {
    log_header "Creating Namespace and Secrets"

    log_step "Creating namespace: ${NAMESPACE}..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Would execute: oc create namespace ${NAMESPACE} --dry-run=client -o yaml"
        cat > "${DRY_RUN_DIR}/namespace/01-namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
EOF
        log_success "Generated: ${DRY_RUN_DIR}/namespace/01-namespace.yaml"
    else
        if oc get namespace "${NAMESPACE}" &> /dev/null; then
            log_info "Namespace ${NAMESPACE} already exists"
        else
            oc create namespace "${NAMESPACE}"
            log_success "Namespace created: ${NAMESPACE}"
        fi
    fi

    log_step "Creating HuggingFace token secret..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Would execute: oc create secret generic huggingface-token \\"
        log_info "  --from-literal=HF_CLI_TOKEN=\${HF_CLI_TOKEN} \\"
        log_info "  -n ${NAMESPACE}"

        cat > "${DRY_RUN_DIR}/namespace/02-huggingface-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: huggingface-token
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  HF_CLI_TOKEN: ${HF_CLI_TOKEN}
EOF
        log_success "Generated: ${DRY_RUN_DIR}/namespace/02-huggingface-secret.yaml"
    else
        if oc get secret huggingface-token -n "${NAMESPACE}" &> /dev/null; then
            log_warning "Secret huggingface-token already exists in ${NAMESPACE}, deleting and recreating..."
            oc delete secret huggingface-token -n "${NAMESPACE}"
        fi

        oc create secret generic huggingface-token \
            --from-literal=HF_CLI_TOKEN="${HF_CLI_TOKEN}" \
            -n "${NAMESPACE}"
        log_success "HuggingFace token secret created in ${NAMESPACE}"
    fi

    echo ""
}

deploy_reflector() {
    log_header "Deploying Reflector"

    log_step "Adding Emberstack Helm repository..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Would execute: helm repo add emberstack https://emberstack.github.io/helm-charts"
        log_info "Would execute: helm repo update"
    else
        if helm repo list 2>/dev/null | grep -q "emberstack"; then
            log_info "Emberstack repository already added"
        else
            helm repo add emberstack https://emberstack.github.io/helm-charts
            log_success "Added Emberstack Helm repository"
        fi

        helm repo update
        log_success "Updated Helm repositories"
    fi

    log_step "Installing Reflector using Helm..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Would execute: helm upgrade --install reflector emberstack/reflector \\"
        log_info "  --namespace reflector \\"
        log_info "  --create-namespace"

        # Generate a dry-run template
        log_info "Generating Helm template..."
        helm template reflector emberstack/reflector \
            --namespace reflector \
            > "${DRY_RUN_DIR}/reflector/reflector-manifests.yaml" 2>/dev/null || {
            log_warning "Could not generate Helm template (repo may need to be added first)"
            echo "# Helm template could not be generated in dry-run mode" > "${DRY_RUN_DIR}/reflector/reflector-manifests.yaml"
            echo "# Run: helm template reflector emberstack/reflector --namespace reflector" >> "${DRY_RUN_DIR}/reflector/reflector-manifests.yaml"
        }
        log_success "Generated: ${DRY_RUN_DIR}/reflector/reflector-manifests.yaml"
    else
        if helm upgrade --install reflector emberstack/reflector \
            --namespace reflector \
            --create-namespace 2>&1 | while IFS= read -r line; do
            echo -e "${CYAN}  [helm]${NC} $line"
        done; then
            log_success "Reflector installed successfully"
        else
            log_error "Reflector installation failed"
            return 1
        fi

        log_step "Waiting for Reflector to be ready..."
        if oc wait --for=condition=available --timeout=120s deployment/reflector -n reflector 2>/dev/null; then
            log_success "Reflector is ready"
        else
            log_warning "Reflector deployment timeout - check with: oc get pods -n reflector"
        fi

        log_info "Verify with: oc get pods -n reflector"
    fi

    echo ""
}

deploy_kueue() {
    log_header "Deploying Kueue"

    log_step "Installing Kueue using kubectl..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Would execute: kubectl apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.9.1/manifests.yaml"
    else
        log_info "Installing Kueue..."
        if kubectl apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.9.1/manifests.yaml 2>&1 | while IFS= read -r line; do
            echo -e "${CYAN}  [kubectl]${NC} $line"
        done; then
            log_success "Kueue CRDs and controller installed"
        else
            log_error "Kueue installation failed"
            return 1
        fi

        log_step "Waiting for Kueue controller to be ready..."
        if oc wait --for=condition=available --timeout=120s deployment/kueue-controller-manager -n kueue-system 2>/dev/null; then
            log_success "Kueue controller is ready"
        else
            log_warning "Kueue controller timeout - check with: oc get pods -n kueue-system"
        fi
    fi

    log_step "Applying Kueue configurations..."

    if [[ "$DRY_RUN" == "true" ]]; then
        cp "${KUEUE_DIR}/01-resource-flavor.yaml" "${DRY_RUN_DIR}/kueue/01-resource-flavor.yaml"
        log_success "Copied: ${DRY_RUN_DIR}/kueue/01-resource-flavor.yaml"
    else
        oc apply -f "${KUEUE_DIR}/01-resource-flavor.yaml"
        log_success "ResourceFlavor applied"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        cp "${KUEUE_DIR}/02-cluster-queue.yaml" "${DRY_RUN_DIR}/kueue/02-cluster-queue.yaml"
        log_success "Copied: ${DRY_RUN_DIR}/kueue/02-cluster-queue.yaml"
    else
        oc apply -f "${KUEUE_DIR}/02-cluster-queue.yaml"
        log_success "ClusterQueue applied"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        envsubst < "${KUEUE_DIR}/03-local-queue.yaml" > "${DRY_RUN_DIR}/kueue/03-local-queue.yaml"
        log_success "Generated: ${DRY_RUN_DIR}/kueue/03-local-queue.yaml"
    else
        local temp_queue_file="${KUEUE_DIR}/03-local-queue-generated.yaml"
        envsubst < "${KUEUE_DIR}/03-local-queue.yaml" > "$temp_queue_file"
        oc apply -f "$temp_queue_file"
        log_success "LocalQueue applied to namespace: ${NAMESPACE}"
        rm -f "$temp_queue_file"
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        echo -e "\n${GREEN}${BOLD}Kueue Configuration:${NC}"
        echo -e "  ClusterQueue: ${CYAN}benchmark-cluster-queue${NC}"
        echo -e "  LocalQueue: ${CYAN}guidellm-jobs${NC} in namespace ${CYAN}${NAMESPACE}${NC}"
        echo -e "  Resources: ${CYAN}50 CPU, 100Gi memory${NC}\n"
    fi

    echo ""
}

validate_env_vars() {
    if [[ "$SKIP_VALIDATION" == "true" ]]; then
        log_warning "Skipping environment variable validation (SKIP_VALIDATION=true)"
        return 0
    fi

    log_step "Validating required environment variables..."

    local missing_vars=()

    [[ -z "${NAMESPACE:-}" ]] && missing_vars+=("NAMESPACE")
    [[ -z "${HF_CLI_TOKEN:-}" ]] && missing_vars+=("HF_CLI_TOKEN")

    if [[ "$DEPLOY_MLFLOW" == "true" ]]; then
        [[ -z "${POSTGRES_PASSWORD:-}" ]] && missing_vars+=("POSTGRES_PASSWORD")
        [[ -z "${AWS_ACCESS_KEY_ID:-}" ]] && missing_vars+=("AWS_ACCESS_KEY_ID")
        [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]] && missing_vars+=("AWS_SECRET_ACCESS_KEY")
        [[ -z "${S3_BUCKET_NAME:-}" ]] && missing_vars+=("S3_BUCKET_NAME")
        [[ -z "${AWS_REGION:-}" ]] && missing_vars+=("AWS_REGION")
        [[ -z "${MLFLOW_ADMIN_PASSWORD:-}" ]] && missing_vars+=("MLFLOW_ADMIN_PASSWORD")
    fi

    if [[ "$DEPLOY_GITHUB_RUNNERS" == "true" ]]; then
        [[ -z "${GITHUB_TOKEN:-}" ]] && missing_vars+=("GITHUB_TOKEN")
        [[ -z "${GITHUB_OWNER:-}" ]] && missing_vars+=("GITHUB_OWNER")
    fi

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            echo -e "  ${RED}•${NC} $var"
        done
        log_info "Please add these to your .env file or export them in your shell."
        exit 1
    fi

    log_success "All required environment variables are set"
}

deploy_mlflow() {
    log_header "Deploying MLflow"

    log_step "Creating MLflow namespace and secrets..."

    if [[ "$DRY_RUN" == "true" ]]; then
        local output_file="${DRY_RUN_DIR}/mlflow/01-namespace.yaml"
        envsubst < "${MLFLOW_DIR}/01-namespace.yaml" > "$output_file"
        log_success "Generated: $output_file"
    else
        local temp_ns_file="${MLFLOW_DIR}/01-namespace-generated.yaml"
        envsubst < "${MLFLOW_DIR}/01-namespace.yaml" > "$temp_ns_file"
        oc apply -f "$temp_ns_file"
        log_success "Namespace and secrets created"
        rm -f "$temp_ns_file"
    fi

    log_step "Deploying PostgreSQL database..."
    if [[ "$DRY_RUN" == "true" ]]; then
        cp "${MLFLOW_DIR}/02-postgresql.yaml" "${DRY_RUN_DIR}/mlflow/02-postgresql.yaml"
        log_success "Copied: ${DRY_RUN_DIR}/mlflow/02-postgresql.yaml"
    else
        oc apply -f "${MLFLOW_DIR}/02-postgresql.yaml"
        log_success "PostgreSQL deployment created"

        log_step "Waiting for PostgreSQL to be ready..."
        if oc wait --for=condition=available --timeout=300s deployment/postgresql -n mlflow 2>/dev/null; then
            log_success "PostgreSQL is ready"
        else
            log_warning "PostgreSQL deployment timeout - check with: oc get pods -n mlflow"
        fi
    fi

    log_step "Deploying MLflow server..."
    if [[ "$DRY_RUN" == "true" ]]; then
        cp "${MLFLOW_DIR}/03-mlflow.yaml" "${DRY_RUN_DIR}/mlflow/03-mlflow.yaml"
        log_success "Copied: ${DRY_RUN_DIR}/mlflow/03-mlflow.yaml"
    else
        oc apply -f "${MLFLOW_DIR}/03-mlflow.yaml"
        log_success "MLflow deployment created"
    fi

    log_step "Creating MLflow route..."
    if [[ "$DRY_RUN" == "true" ]]; then
        cp "${MLFLOW_DIR}/04-route.yaml" "${DRY_RUN_DIR}/mlflow/04-route.yaml"
        log_success "Copied: ${DRY_RUN_DIR}/mlflow/04-route.yaml"
    else
        oc apply -f "${MLFLOW_DIR}/04-route.yaml"
        log_success "MLflow route created"

        log_step "Waiting for MLflow to be ready..."
        if oc wait --for=condition=available --timeout=300s deployment/mlflow-server -n mlflow 2>/dev/null; then
            log_success "MLflow is ready"
        else
            log_warning "MLflow deployment timeout - check with: oc get pods -n mlflow"
        fi

        log_step "Retrieving MLflow URL..."
        if MLFLOW_URL=$(oc get route mlflow -n mlflow -o jsonpath='{.spec.host}' 2>/dev/null); then
            echo -e "\n${GREEN}${BOLD}MLflow is available at:${NC}"
            echo -e "  ${CYAN}https://${MLFLOW_URL}${NC}"
            echo -e "\n${BOLD}Credentials:${NC}"
            echo -e "  Username: ${CYAN}admin${NC}"
            echo -e "  Password: ${CYAN}${MLFLOW_ADMIN_PASSWORD}${NC}\n"
        else
            log_warning "Could not retrieve MLflow URL. Check manually with: oc get route -n mlflow"
        fi
    fi
}

deploy_github_runners() {
    log_header "Deploying GitHub Runners"

    log_step "Creating GitHub runners namespace..."

    if [[ "$DRY_RUN" == "true" ]]; then
        local output_file="${DRY_RUN_DIR}/github-runners/01-namespace.yaml"
        envsubst < "${GITHUB_RUNNERS_DIR}/01-namespace.yaml" > "$output_file"
        log_success "Generated: $output_file"
    else
        local temp_ns_file="${GITHUB_RUNNERS_DIR}/01-namespace-generated.yaml"
        envsubst < "${GITHUB_RUNNERS_DIR}/01-namespace.yaml" > "$temp_ns_file"
        oc apply -f "$temp_ns_file"
        log_success "Namespace created with GitHub token"
        rm -f "$temp_ns_file"
    fi

    log_step "Creating RBAC resources..."
    if [[ "$DRY_RUN" == "true" ]]; then
        cp "${GITHUB_RUNNERS_DIR}/02-controller-rbac.yaml" "${DRY_RUN_DIR}/github-runners/02-controller-rbac.yaml"
        log_success "Copied: ${DRY_RUN_DIR}/github-runners/02-controller-rbac.yaml"
    else
        oc apply -f "${GITHUB_RUNNERS_DIR}/02-controller-rbac.yaml"
        log_success "RBAC resources created"
    fi

    log_step "Deploying GitHub runner StatefulSet..."

    if [[ "$DRY_RUN" == "true" ]]; then
        local output_file="${DRY_RUN_DIR}/github-runners/03-runner-deployment.yaml"
        envsubst < "${GITHUB_RUNNERS_DIR}/03-runner-deployment.yaml" > "$output_file"
        log_success "Generated: $output_file"
    else
        local temp_runner_file="${GITHUB_RUNNERS_DIR}/03-runner-deployment-generated.yaml"
        envsubst < "${GITHUB_RUNNERS_DIR}/03-runner-deployment.yaml" > "$temp_runner_file"
        oc apply -f "$temp_runner_file"
        log_success "GitHub runner StatefulSet created"
        rm -f "$temp_runner_file"
    fi

    log_step "Creating OpenShift SCC..."
    if [[ "$DRY_RUN" == "true" ]]; then
        cp "${GITHUB_RUNNERS_DIR}/04-openshift-scc.yaml" "${DRY_RUN_DIR}/github-runners/04-openshift-scc.yaml"
        log_success "Copied: ${DRY_RUN_DIR}/github-runners/04-openshift-scc.yaml"
    else
        oc apply -f "${GITHUB_RUNNERS_DIR}/04-openshift-scc.yaml"
        log_success "SCC created"
    fi

    # log_step "Creating HPA (Horizontal Pod Autoscaler)..."
    # oc apply -f "${GITHUB_RUNNERS_DIR}/05-hpa.yaml"
    # log_success "HPA created"

    if [[ "$DRY_RUN" != "true" ]]; then
        log_step "Waiting for runner pods to start..."
        sleep 5

        if oc get pods -n github-runners 2>/dev/null | grep -q "github-runner"; then
            log_success "GitHub runner pods created"
            log_info "Check runner status: oc get pods -n github-runners"
            log_info "View logs: oc logs -f github-runner-0 -n github-runners"
        else
            log_warning "Runner pods not yet visible. Check with: oc get pods -n github-runners"
        fi
    fi

    echo -e "\n${GREEN}${BOLD}GitHub Runners Configuration:${NC}"
    echo -e "  Owner/Org: ${CYAN}${GITHUB_OWNER}${NC}"
    echo -e "  Repository: ${CYAN}${GITHUB_REPOSITORY:-<organization-wide>}${NC}"
    echo -e "  Labels: ${CYAN}${RUNNER_LABELS:-openshift,self-hosted}${NC}\n"
}

build_custom_image() {
    log_header "Building Custom Guidellm Image"

    log_step "Creating ImageStream..."
    if [[ "$DRY_RUN" == "true" ]]; then
        cp "${BUILD_DIR}/imagestream.yaml" "${DRY_RUN_DIR}/build/imagestream.yaml"
        log_success "Copied: ${DRY_RUN_DIR}/build/imagestream.yaml"
    else
        oc apply -f "${BUILD_DIR}/imagestream.yaml"
        log_success "ImageStream created"
    fi

    log_step "Creating BuildConfig..."
    if [[ "$DRY_RUN" == "true" ]]; then
        cp "${BUILD_DIR}/buildconfig.yaml" "${DRY_RUN_DIR}/build/buildconfig.yaml"
        log_success "Copied: ${DRY_RUN_DIR}/build/buildconfig.yaml"
    else
        oc apply -f "${BUILD_DIR}/buildconfig.yaml"
        log_success "BuildConfig created"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Dry-run mode: Skipping actual image build"
        log_info "Build files copied to ${DRY_RUN_DIR}/build/"
    else
        log_step "Starting build from directory: ${BUILD_DIR}"
        log_info "This may take several minutes..."

        if oc start-build guidellm-custom-build --from-dir="${BUILD_DIR}" --follow 2>&1 | while IFS= read -r line; do
            echo -e "${CYAN}  [build]${NC} $line"
        done; then
            log_success "Image build completed successfully"

            CURRENT_PROJECT=$(oc project -q)
            IMAGE_NAME="image-registry.openshift-image-registry.svc:5000/${CURRENT_PROJECT}/guidellm-custom:latest"

            echo -e "\n${GREEN}${BOLD}Image available at:${NC}"
            echo -e "  ${CYAN}${IMAGE_NAME}${NC}\n"
        else
            log_error "Image build failed. Check logs with: oc logs -f bc/guidellm-custom-build"
            return 1
        fi
    fi
}

print_summary() {
    log_header "Deployment Summary"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${BOLD}Dry-run completed - manifests generated:${NC}"
        [[ "$DEPLOY_REFLECTOR" == "true" ]] && echo -e "  ${GREEN}✓${NC} Reflector docs and manifests in ${CYAN}${DRY_RUN_DIR}/reflector/${NC}"
        [[ "$DEPLOY_KUEUE" == "true" ]] && echo -e "  ${GREEN}✓${NC} Kueue docs and manifests in ${CYAN}${DRY_RUN_DIR}/kueue/${NC}"
        echo -e "  ${GREEN}✓${NC} Namespace and secrets in ${CYAN}${DRY_RUN_DIR}/namespace/${NC}"
        [[ "$DEPLOY_MLFLOW" == "true" ]] && echo -e "  ${GREEN}✓${NC} MLflow manifests in ${CYAN}${DRY_RUN_DIR}/mlflow/${NC}"
        [[ "$DEPLOY_GITHUB_RUNNERS" == "true" ]] && echo -e "  ${GREEN}✓${NC} GitHub Runners manifests in ${CYAN}${DRY_RUN_DIR}/github-runners/${NC}"
        [[ "$BUILD_IMAGE" == "true" ]] && echo -e "  ${GREEN}✓${NC} Build manifests in ${CYAN}${DRY_RUN_DIR}/build/${NC}"

        echo -e "\n${BOLD}To deploy for real, run:${NC}"
        echo -e "  ./bootstrap.sh"
        echo -e "\n${BOLD}To inspect manifests:${NC}"
        echo -e "  ls -la ${DRY_RUN_DIR}/"
        [[ "$DEPLOY_REFLECTOR" == "true" ]] && echo -e "  cat ${DRY_RUN_DIR}/reflector/*.yaml"
        [[ "$DEPLOY_KUEUE" == "true" ]] && echo -e "  cat ${DRY_RUN_DIR}/kueue/*.yaml"
        echo -e "  cat ${DRY_RUN_DIR}/namespace/*.yaml"
        [[ "$DEPLOY_MLFLOW" == "true" ]] && echo -e "  cat ${DRY_RUN_DIR}/mlflow/*.yaml"
        [[ "$DEPLOY_GITHUB_RUNNERS" == "true" ]] && echo -e "  cat ${DRY_RUN_DIR}/github-runners/*.yaml"
    else
        echo -e "${BOLD}Components deployed:${NC}"
        [[ "$DEPLOY_REFLECTOR" == "true" ]] && echo -e "  ${GREEN}✓${NC} Reflector"
        [[ "$DEPLOY_KUEUE" == "true" ]] && echo -e "  ${GREEN}✓${NC} Kueue (job batching)"
        echo -e "  ${GREEN}✓${NC} Namespace: ${CYAN}${NAMESPACE}${NC}"
        echo -e "  ${GREEN}✓${NC} HuggingFace token secret"
        [[ "$DEPLOY_MLFLOW" == "true" ]] && echo -e "  ${GREEN}✓${NC} MLflow"
        [[ "$DEPLOY_GITHUB_RUNNERS" == "true" ]] && echo -e "  ${GREEN}✓${NC} GitHub Runners"
        [[ "$BUILD_IMAGE" == "true" ]] && echo -e "  ${GREEN}✓${NC} Custom Guidellm Image"
    fi

    echo -e "\n${BOLD}Useful commands:${NC}"

    if [[ "$DEPLOY_REFLECTOR" == "true" ]]; then
        echo -e "\n${CYAN}Reflector:${NC}"
        echo -e "  oc get pods -n reflector"
        echo -e "  oc logs -f deployment/reflector -n reflector"
    fi

    if [[ "$DEPLOY_KUEUE" == "true" ]]; then
        echo -e "\n${CYAN}Kueue:${NC}"
        echo -e "  oc get pods -n kueue-system"
        echo -e "  oc get clusterqueues"
        echo -e "  oc get localqueues -n ${NAMESPACE}"
    fi

    if [[ "$DEPLOY_MLFLOW" == "true" ]]; then
        echo -e "\n${CYAN}MLflow:${NC}"
        echo -e "  oc get pods -n mlflow"
        echo -e "  oc logs -f deployment/mlflow-server -n mlflow"
        echo -e "  oc get route mlflow -n mlflow"
    fi

    if [[ "$DEPLOY_GITHUB_RUNNERS" == "true" ]]; then
        echo -e "\n${CYAN}GitHub Runners:${NC}"
        echo -e "  oc get pods -n github-runners"
        echo -e "  oc logs -f github-runner-0 -n github-runners"
        echo -e "  oc get hpa -n github-runners"
    fi

    if [[ "$BUILD_IMAGE" == "true" ]]; then
        echo -e "\n${CYAN}Image Build:${NC}"
        echo -e "  oc get builds"
        echo -e "  oc get imagestream guidellm-custom"
    fi

    echo -e "\n${GREEN}${BOLD}Bootstrap completed successfully!${NC}\n"
}

main() {
    log_header "llm-d-bench bootstrap"

    echo -e "${BOLD}This script will deploy:${NC}"
    [[ "$DEPLOY_REFLECTOR" == "true" ]] && echo -e "  ${CYAN}•${NC} Reflector (for secret mirroring)"
    [[ "$DEPLOY_KUEUE" == "true" ]] && echo -e "  ${CYAN}•${NC} Kueue (for job batching)"
    [[ "$DEPLOY_MLFLOW" == "true" ]] && echo -e "  ${CYAN}•${NC} MLflow tracking server"
    [[ "$DEPLOY_GITHUB_RUNNERS" == "true" ]] && echo -e "  ${CYAN}•${NC} GitHub self-hosted runners"
    [[ "$BUILD_IMAGE" == "true" ]] && echo -e "  ${CYAN}•${NC} Custom Guidellm container image"
    echo ""

    check_prerequisites

    load_env_file
    validate_env_vars

    setup_dry_run

    if [[ "$DEPLOY_REFLECTOR" == "true" ]]; then
        deploy_reflector
    else
        log_info "Skipping Reflector deployment (DEPLOY_REFLECTOR=false)"
    fi

    if [[ "$DEPLOY_KUEUE" == "true" ]]; then
        deploy_kueue
    else
        log_info "Skipping Kueue deployment (DEPLOY_KUEUE=false)"
    fi

    deploy_namespace_secrets

    if [[ "$DEPLOY_MLFLOW" == "true" ]]; then
        deploy_mlflow
    else
        log_info "Skipping MLflow deployment (DEPLOY_MLFLOW=false)"
    fi

    if [[ "$DEPLOY_GITHUB_RUNNERS" == "true" ]]; then
        deploy_github_runners
    else
        log_info "Skipping GitHub runners deployment (DEPLOY_GITHUB_RUNNERS=false)"
    fi

    if [[ "$BUILD_IMAGE" == "true" ]]; then
        build_custom_image
    else
        log_info "Skipping image build (BUILD_IMAGE=false)"
    fi

    print_summary
}

case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --help, -h              Show this help message"
        echo "  --dry-run               Generate manifests without deploying"
        echo "  --skip-validation       Skip environment variable validation"
        echo ""
        echo "Environment variables:"
        echo "  DEPLOY_REFLECTOR=true|false        Deploy Reflector (default: true)"
        echo "  DEPLOY_KUEUE=true|false            Deploy Kueue (default: false)"
        echo "  DEPLOY_MLFLOW=true|false           Deploy MLflow (default: true)"
        echo "  DEPLOY_GITHUB_RUNNERS=true|false   Deploy GitHub runners (default: true)"
        echo "  BUILD_IMAGE=true|false              Build custom image (default: true)"
        echo "  SKIP_VALIDATION=true|false          Skip env var validation (default: false)"
        echo "  DRY_RUN=true|false                  Generate manifests only (default: false)"
        echo ""
        echo "Examples:"
        echo "  ./bootstrap.sh --dry-run"
        echo "  DRY_RUN=true ./bootstrap.sh"
        echo "  DEPLOY_MLFLOW=true DEPLOY_GITHUB_RUNNERS=false ./bootstrap.sh"
        echo ""
        exit 0
        ;;
    --dry-run)
        DRY_RUN=true
        shift
        ;;
    --skip-validation)
        SKIP_VALIDATION=true
        shift
        ;;
esac

main "$@"
