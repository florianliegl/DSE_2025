# Detect platform
UNAME_S := $(shell uname -s)
# Windows detection (Git Bash or native PowerShell)
ifeq ($(OS),Windows_NT)
	IS_WINDOWS := true
else
	IS_WINDOWS := false
endif

# Commands
ifeq ($(IS_WINDOWS),true)
	SHELL_SCRIPT := powershell -ExecutionPolicy Bypass -File
	START_SCRIPT := scripts/start-minikube.ps1
	DATE_CMD := powershell -Command "Get-Date -Format 'yyyyMMdd-HHmmss'"
else
	SHELL_SCRIPT := sh
	START_SCRIPT := scripts/start-minikube.sh
	DATE_CMD := date +"%Y%m%d-%H%M%S"
endif

# Namespace
NAMESPACE := vehicle-platform

# Generate timestamp for dynamic version tags
VERSION_TAG := $(shell $(DATE_CMD))

# Docker build settings
DOCKER_BUILD_CMD := docker build
DOCKER_LOAD_CMD := :
ifeq ($(IS_WINDOWS),true)
	DOCKER_BUILD_CMD := docker build
	DOCKER_LOAD_CMD := minikube image load
else
	DOCKER_BUILD_CMD := eval $$(minikube docker-env) && docker build
	DOCKER_LOAD_CMD := :
endif

DOCKER_SERVICES := location-sender location-tracker distance-monitor \
                   emergency-break central-director visor datamock

# Kubernetes configuration services
K8S_SERVICES := mbroker api-gateway

# Define a function to update image tag in deployment files
# The function takes a service name as parameter
define update-deployment-image
	@echo "Updating deployment file for $(1)..."
	@if [ -f services/$(1)/k8s/deployment.yaml ]; then \
		if [ "$(IS_WINDOWS)" = "true" ]; then \
			powershell -Command "(Get-Content services/$(1)/k8s/deployment.yaml) -replace 'image: $(1)-service:.*', 'image: $(1)-service:$(VERSION_TAG)' | Set-Content services/$(1)/k8s/deployment.yaml"; \
		else \
			sed -i.bak 's|image: $(1)-service:.*|image: $(1)-service:$(VERSION_TAG)|g' services/$(1)/k8s/deployment.yaml; \
			rm -f services/$(1)/k8s/deployment.yaml.bak; \
		fi; \
	fi
endef

.PHONY: start deploy delete build-docker deploy-docker \
		deploy-k8s build-all deploy-all delete-all \
		$(DOCKER_SERVICES) $(K8S_SERVICES) versions

# Start minikube
start:
	$(SHELL_SCRIPT) $(START_SCRIPT)

# Build all Docker services
build-docker: $(DOCKER_SERVICES)

# Deploy all Docker services to Kubernetes
deploy-docker: 
	@for service in $(DOCKER_SERVICES); do \
		echo "Deploying $$service..."; \
		kubectl apply -f services/$$service/k8s/deployment.yaml; \
		kubectl apply -f services/$$service/k8s/service.yaml; \
	done

# Build individual Docker services with dynamic versioning
$(DOCKER_SERVICES):
	@echo "Building $@ service..."
	@echo "Using dynamic tag: $(VERSION_TAG)"
	$(DOCKER_BUILD_CMD) -t $@-service:$(VERSION_TAG) -t $@-service:latest services/$@
	$(DOCKER_LOAD_CMD) $@-service:$(VERSION_TAG)
	$(call update-deployment-image,$@)
	@echo "Applying updated deployment for $@..."
	kubectl apply -f services/$@/k8s/deployment.yaml -n $(NAMESPACE) || echo "Deployment $@ not found, will be created when you run deploy-docker"

# Deploy Kubernetes-specific services
deploy-k8s:
	@for service in $(K8S_SERVICES); do \
		echo "Deploying $$service..."; \
		$(MAKE) deploy-$$service; \
	done

# Deploy namespace first
deploy-namespace:
	kubectl apply -f k8s/namespace.yaml

# Deployment targets for Kubernetes services
deploy-mbroker:
	kubectl apply -f services/mbroker/k8s/secret.yaml
	kubectl apply -f services/mbroker/k8s/deployment.yaml
	kubectl apply -f services/mbroker/k8s/service.yaml

deploy-api-gateway:
	kubectl apply -f services/passenger-api-gateway/k8s/kong-deployment.yaml
	# kubectl apply -f services/passenger-api-gateway/k8s/kong-service.yaml
	kubectl apply -f services/passenger-api-gateway/k8s/kong-config.yaml

deploy-datamock:
	kubectl apply -f services/datamock/k8s/deployment.yaml
	kubectl apply -f services/datamock/k8s/service.yaml

# Comprehensive deploy target
deploy-all: deploy-namespace deploy-k8s build-docker deploy-docker

# Delete targets
delete-docker:
	@for service in $(DOCKER_SERVICES); do \
		echo "Deleting $$service..."; \
		kubectl delete -f services/$$service/k8s/service.yaml; \
		kubectl delete -f services/$$service/k8s/deployment.yaml; \
	done

delete-k8s:
	@for service in $(K8S_SERVICES); do \
		echo "Deleting $$service..."; \
		$(MAKE) delete-$$service; \
	done

delete-mbroker:
	kubectl delete -f services/mbroker/k8s/service.yaml
	kubectl delete -f services/mbroker/k8s/deployment.yaml
	kubectl delete -f services/mbroker/k8s/secret.yaml

delete-api-gateway:
	kubectl delete -f services/passenger-api-gateway/k8s/kong-service.yaml
	kubectl delete -f services/passenger-api-gateway/k8s/kong-deployment.yaml
	kubectl delete -f services/passenger-api-gateway/k8s/kong-config.yaml

delete-datamock:
	kubectl delete -f services/datamock/k8s/service.yaml
	kubectl delete -f services/datamock/k8s/deployment.yaml

# Delete everything
delete-all: delete-k8s delete-docker

# Status and troubleshooting
status:
	@echo -e "\nStatus of all services in the $(NAMESPACE) namespace:\n"
	kubectl get namespaces
	@echo -e "\n"
	kubectl get deployments -n $(NAMESPACE)
	@echo -e "\n"
	kubectl get services -n $(NAMESPACE)
	@echo -e "\n"
	kubectl get pods -n $(NAMESPACE)

# Logs for services
logs-%:
	kubectl logs -n $(NAMESPACE) -l app=$*

# Port forwarding
forward-%:
	@case "$*" in \
		mbroker) \
			kubectl port-forward -n $(NAMESPACE) service/rabbitmq 5672:5672 15672:15672 \
			;; \
		api-gateway) \
			kubectl port-forward -n $(NAMESPACE) service/kong-proxy 8000:80 8444:8444 \
			;; \
		datamock) \
			kubectl port-forward -n $(NAMESPACE) service/datamock-service 8000:8000 \
			;; \
		*) \
			kubectl port-forward -n $(NAMESPACE) service/$*-service 8000:8000 \
			;; \
	esac

# Update a specific service (build + restart deployment)
update-%:
	@echo "Updating $* service..."
	$(MAKE) $*
	
# Update all services
update-all:
	@echo "Updating all services with dynamic tag: $(VERSION_TAG)"
	@for service in $(DOCKER_SERVICES); do \
		echo "Updating $$service..."; \
		$(MAKE) $$service; \
	done

# Show image versions currently in use
versions:
	@echo "Current image versions in the $(NAMESPACE) namespace:"
	@kubectl get deployments -n $(NAMESPACE) -o jsonpath="{range .items[*]}{.metadata.name}{': '}{.spec.template.spec.containers[0].image}{'\n'}{end}"
