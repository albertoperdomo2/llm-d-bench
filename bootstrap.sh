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

# Deployment flags
DEPLOY_MLFLOW="${DEPLOY_MLFLOW:-true}"
DEPLOY_GITHUB_RUNNERS="${DEPLOY_GITHUB_RUNNERS:-true}"
BUILD_IMAGE="${BUILD_IMAGE:-true}"
SKIP_VALIDATION="${SKIP_VALIDATION:-false}"

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

    log_step "Checking cluster connection..."
    if oc whoami &> /dev/null; then
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

validate_env_vars() {
    if [[ "$SKIP_VALIDATION" == "true" ]]; then
        log_warning "Skipping environment variable validation (SKIP_VALIDATION=true)"
        return 0
    fi

    log_step "Validating required environment variables..."

    local missing_vars=()

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

    local temp_ns_file="${MLFLOW_DIR}/01-namespace-generated.yaml"

    envsubst < "${MLFLOW_DIR}/01-namespace.yaml" > "$temp_ns_file"

    oc apply -f "$temp_ns_file"
    log_success "Namespace and secrets created"

    rm -f "$temp_ns_file"

    log_step "Deploying PostgreSQL database..."
    oc apply -f "${MLFLOW_DIR}/02-postgresql.yaml"
    log_success "PostgreSQL deployment created"

    log_step "Waiting for PostgreSQL to be ready..."
    if oc wait --for=condition=available --timeout=300s deployment/postgresql -n mlflow 2>/dev/null; then
        log_success "PostgreSQL is ready"
    else
        log_warning "PostgreSQL deployment timeout - check with: oc get pods -n mlflow"
    fi

    log_step "Deploying MLflow server..."
    oc apply -f "${MLFLOW_DIR}/03-mlflow.yaml"
    log_success "MLflow deployment created"

    log_step "Creating MLflow route..."
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
}

deploy_github_runners() {
    log_header "Deploying GitHub Runners"

    log_step "Creating GitHub runners namespace..."

    local temp_ns_file="${GITHUB_RUNNERS_DIR}/01-namespace-generated.yaml"
    envsubst < "${GITHUB_RUNNERS_DIR}/01-namespace.yaml" > "$temp_ns_file"

    oc apply -f "$temp_ns_file"
    log_success "Namespace created with GitHub token"

    rm -f "$temp_ns_file"

    log_step "Creating RBAC resources..."
    oc apply -f "${GITHUB_RUNNERS_DIR}/02-controller-rbac.yaml"
    log_success "RBAC resources created"

    log_step "Deploying GitHub runner StatefulSet..."

    local temp_runner_file="${GITHUB_RUNNERS_DIR}/03-runner-deployment-generated.yaml"
    envsubst < "${GITHUB_RUNNERS_DIR}/03-runner-deployment.yaml" > "$temp_runner_file"

    oc apply -f "$temp_runner_file"
    log_success "GitHub runner StatefulSet created"

    rm -f "$temp_runner_file"

    log_step "Creating OpenShift SCC..."
    oc apply -f "${GITHUB_RUNNERS_DIR}/04-openshift-scc.yaml"
    log_success "SCC created"

    # log_step "Creating HPA (Horizontal Pod Autoscaler)..."
    # oc apply -f "${GITHUB_RUNNERS_DIR}/05-hpa.yaml"
    # log_success "HPA created"

    log_step "Waiting for runner pods to start..."
    sleep 5

    if oc get pods -n github-runners 2>/dev/null | grep -q "github-runner"; then
        log_success "GitHub runner pods created"
        log_info "Check runner status: oc get pods -n github-runners"
        log_info "View logs: oc logs -f github-runner-0 -n github-runners"
    else
        log_warning "Runner pods not yet visible. Check with: oc get pods -n github-runners"
    fi

    echo -e "\n${GREEN}${BOLD}GitHub Runners Configuration:${NC}"
    echo -e "  Owner/Org: ${CYAN}${GITHUB_OWNER}${NC}"
    echo -e "  Repository: ${CYAN}${GITHUB_REPOSITORY:-<organization-wide>}${NC}"
    echo -e "  Labels: ${CYAN}${RUNNER_LABELS:-openshift,self-hosted}${NC}\n"
}

build_custom_image() {
    log_header "Building Custom Guidellm Image"

    log_step "Creating ImageStream..."
    oc apply -f "${BUILD_DIR}/imagestream.yaml"
    log_success "ImageStream created"

    log_step "Creating BuildConfig..."
    oc apply -f "${BUILD_DIR}/buildconfig.yaml"
    log_success "BuildConfig created"

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
}

print_summary() {
    log_header "Deployment Summary"

    echo -e "${BOLD}Components deployed:${NC}"
    [[ "$DEPLOY_MLFLOW" == "true" ]] && echo -e "  ${GREEN}✓${NC} MLflow"
    [[ "$DEPLOY_GITHUB_RUNNERS" == "true" ]] && echo -e "  ${GREEN}✓${NC} GitHub Runners"
    [[ "$BUILD_IMAGE" == "true" ]] && echo -e "  ${GREEN}✓${NC} Custom Guidellm Image"

    echo -e "\n${BOLD}Useful commands:${NC}"

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
    [[ "$DEPLOY_MLFLOW" == "true" ]] && echo -e "  ${CYAN}•${NC} MLflow tracking server"
    [[ "$DEPLOY_GITHUB_RUNNERS" == "true" ]] && echo -e "  ${CYAN}•${NC} GitHub self-hosted runners"
    [[ "$BUILD_IMAGE" == "true" ]] && echo -e "  ${CYAN}•${NC} Custom Guidellm container image"
    echo ""

    check_prerequisites

    load_env_file
    validate_env_vars

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
        echo "  --skip-validation       Skip environment variable validation"
        echo ""
        echo "Environment variables:"
        echo "  DEPLOY_MLFLOW=true|false          Deploy MLflow (default: true)"
        echo "  DEPLOY_GITHUB_RUNNERS=true|false  Deploy GitHub runners (default: true)"
        echo "  BUILD_IMAGE=true|false             Build custom image (default: true)"
        echo "  SKIP_VALIDATION=true|false         Skip env var validation (default: false)"
        echo ""
        echo "Example:"
        echo "  DEPLOY_MLFLOW=true DEPLOY_GITHUB_RUNNERS=false ./bootstrap.sh"
        echo ""
        exit 0
        ;;
    --skip-validation)
        SKIP_VALIDATION=true
        shift
        ;;
esac

main "$@"
