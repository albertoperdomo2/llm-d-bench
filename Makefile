.PHONY: help lint template-benchmark template-cleanup install-benchmark install-cleanup uninstall clean validate

# Default values
NAMESPACE ?= keda
RELEASE_NAME ?= benchmark-test
TARGET_URL ?= http://localhost:8080
MODEL_NAME ?= meta-llama/Llama-3.3-70B-Instruct
CHART_PATH = ./llm-d-bench

help: ## Show this help message
	@echo "llm-d benchmark Helm Chart - Make targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables:"
	@echo "  NAMESPACE      Kubernetes namespace (default: keda)"
	@echo "  RELEASE_NAME   Helm release name (default: benchmark-test)"
	@echo "  TARGET_URL     LLM service URL (default: http://localhost:8080)"
	@echo "  MODEL_NAME     Model name (default: meta-llama/Llama-3.3-70B-Instruct)"
	@echo ""
	@echo "Examples:"
	@echo "  make install-benchmark RELEASE_NAME=test1 TARGET_URL=http://service:8080"
	@echo "  make template-benchmark TARGET_URL=http://service:8080 MODEL_NAME=gpt-4"
	@echo "  make uninstall RELEASE_NAME=test1"

lint: ## Lint the Helm chart
	@echo "Linting Helm chart..."
	@helm lint $(CHART_PATH)

validate: ## Validate Helm chart with example values
	@echo "Validating chart with example values..."
	@helm lint $(CHART_PATH) -f $(CHART_PATH)/examples/benchmark-example.yaml
	@helm lint $(CHART_PATH) -f $(CHART_PATH)/examples/cleanup-example.yaml

template-benchmark: ## Render benchmark job template (dry-run)
	@echo "Rendering benchmark job template..."
	@helm template $(RELEASE_NAME) $(CHART_PATH) \
		--set jobType=benchmark \
		--set benchmark.name=$(RELEASE_NAME) \
		--set benchmark.targetUrl=$(TARGET_URL) \
		--set benchmark.modelName=$(MODEL_NAME) \
		--namespace $(NAMESPACE)

template-cleanup: ## Render cleanup job template (dry-run)
	@echo "Rendering cleanup job template..."
	@helm template cleanup $(CHART_PATH) \
		--set jobType=cleanup \
		--set pvc.create=false \
		--namespace $(NAMESPACE)

install-benchmark: ## Install benchmark job
	@echo "Installing benchmark job..."
	@helm install $(RELEASE_NAME) $(CHART_PATH) \
		--set jobType=benchmark \
		--set benchmark.name=$(RELEASE_NAME) \
		--set benchmark.targetUrl=$(TARGET_URL) \
		--set benchmark.modelName=$(MODEL_NAME) \
		--namespace $(NAMESPACE) \
		--create-namespace

install-benchmark-with-pvc: ## Install benchmark job with PVC creation
	@echo "Installing benchmark job with PVC..."
	@helm install $(RELEASE_NAME) $(CHART_PATH) \
		--set jobType=benchmark \
		--set benchmark.name=$(RELEASE_NAME) \
		--set benchmark.targetUrl=$(TARGET_URL) \
		--set benchmark.modelName=$(MODEL_NAME) \
		--set pvc.create=true \
		--namespace $(NAMESPACE) \
		--create-namespace

install-cleanup: ## Install cleanup job
	@echo "Installing cleanup job..."
	@helm install cleanup $(CHART_PATH) \
		--set jobType=cleanup \
		--set pvc.create=false \
		--namespace $(NAMESPACE)

install-pvc-only: ## Install only PVC
	@echo "Installing PVC only..."
	@helm install storage $(CHART_PATH) \
		-f $(CHART_PATH)/examples/pvc-only-example.yaml \
		--namespace $(NAMESPACE) \
		--create-namespace

uninstall: ## Uninstall a Helm release
	@echo "Uninstalling release $(RELEASE_NAME)..."
	@helm uninstall $(RELEASE_NAME) --namespace $(NAMESPACE)

list: ## List all Helm releases
	@helm list --namespace $(NAMESPACE)

status: ## Show status of a Helm release
	@helm status $(RELEASE_NAME) --namespace $(NAMESPACE)

logs: ## Show logs of the benchmark job
	@oc logs job/$(RELEASE_NAME)-benchmark --namespace $(NAMESPACE) -f

get-jobs: ## List all jobs in namespace
	@oc get jobs --namespace $(NAMESPACE)

get-pvc: ## Show PVC status
	@oc get pvc --namespace $(NAMESPACE)

clean-jobs: ## Delete all completed jobs
	@echo "Deleting completed jobs..."
	@oc delete jobs --field-selector status.successful=1 --namespace $(NAMESPACE)

clean-failed-jobs: ## Delete all failed jobs
	@echo "Deleting failed jobs..."
	@oc delete jobs --field-selector status.failed=1 --namespace $(NAMESPACE)

create-secret: ## Create Hugging Face token secret (requires HF_TOKEN env var)
	@if [ -z "$(HF_TOKEN)" ]; then \
		echo "Error: HF_TOKEN environment variable is required"; \
		echo "Usage: make create-secret HF_TOKEN=your-token"; \
		exit 1; \
	fi
	@echo "Creating Hugging Face token secret..."
	@oc create secret generic huggingface-token \
		--from-literal=HF_CLI_TOKEN=$(HF_TOKEN) \
		--namespace $(NAMESPACE) \
		--dry-run=client -o yaml | oc apply -f -

package: ## Package the Helm chart
	@echo "Packaging Helm chart..."
	@helm package $(CHART_PATH) -d ./dist

clean: ## Clean up generated files
	@echo "Cleaning up..."
	@rm -rf dist/

test-dry-run: ## Test installation with dry-run
	@echo "Testing installation (dry-run)..."
	@helm install $(RELEASE_NAME) $(CHART_PATH) \
		--set jobType=benchmark \
		--set benchmark.targetUrl=$(TARGET_URL) \
		--set benchmark.modelName=$(MODEL_NAME) \
		--namespace $(NAMESPACE) \
		--dry-run --debug

.DEFAULT_GOAL := help
