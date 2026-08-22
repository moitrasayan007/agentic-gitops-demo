REGION      ?= us-east-1
ACCOUNT     ?= $(shell aws sts get-caller-identity --query Account --output text)
REGISTRY    ?= $(ACCOUNT).dkr.ecr.$(REGION).amazonaws.com
IMAGE       ?= $(REGISTRY)/parcel-tracker
TAG         ?= v1
NAMESPACE   ?= parcel-tracker

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: infra
infra: ## Stand up the EKS Auto Mode cluster, ECR, Argo CD, and Kyverno
	cd infra && terraform init && terraform apply

.PHONY: kubeconfig
kubeconfig: ## Point kubectl at the demo cluster
	$$(cd infra && terraform output -raw kubeconfig_command)

.PHONY: argocd-url
argocd-url: ## Print the Argo CD URL (plain HTTP) and admin password
	@echo -n "URL:      "; kubectl -n argocd get svc argocd-server \
		-o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null \
		| sed 's|^|http://|'; echo
	@echo -n "Password: "; kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' 2>/dev/null | base64 -d; echo

.PHONY: destroy
destroy: ## Tear the whole demo down
	cd infra && terraform destroy

.PHONY: login
login: ## Authenticate Docker against ECR
	aws ecr get-login-password --region $(REGION) \
		| docker login --username AWS --password-stdin $(REGISTRY)

.PHONY: image
image: login ## Build and push the multi-arch image (EKS Auto Mode nodes vary)
	docker buildx build \
		--platform linux/amd64,linux/arm64 \
		--build-arg APP_VERSION=$(TAG) \
		-t $(IMAGE):$(TAG) \
		--push app

.PHONY: lint
lint: ## Lint and render the chart locally
	helm lint chart
	helm template parcel-tracker chart --namespace $(NAMESPACE) > /dev/null

.PHONY: policy
policy: ## Run the policy gate locally, exactly as CI does
	helm template parcel-tracker chart --namespace $(NAMESPACE) > /tmp/manifests.yaml
	kyverno apply policy/ --resource /tmp/manifests.yaml --detailed-results

.PHONY: policies
policies: ## Apply the Kyverno policies (Kyverno itself is installed by `make infra`)
	kubectl apply -f policy/

.PHONY: argocd
argocd: policies ## Apply policies, then the AppProject, Application, and agent RBAC
	kubectl apply -f argocd/appproject.yaml
	kubectl apply -f argocd/application.yaml
	kubectl apply -f argocd/agent-rbac.yaml

.PHONY: status
status: ## Show the workload's current state -- the demo's opening shot
	kubectl -n $(NAMESPACE) get pods -o wide
	@echo
	kubectl -n $(NAMESPACE) get events --sort-by=.lastTimestamp | tail -15
	@echo
	argocd app get parcel-tracker || true

.PHONY: agent
agent: ## Run the triage agent against the live cluster
	python agent/triage_agent.py --namespace $(NAMESPACE)

.PHONY: agent-dry-run
agent-dry-run: ## Diagnose only; the pull-request tool is withheld
	python agent/triage_agent.py --namespace $(NAMESPACE) --dry-run

.PHONY: agent-hardened
agent-hardened: ## Run the agent with provenance hardening against injection
	python agent/triage_agent.py --namespace $(NAMESPACE) --hardened

.PHONY: inject-pod
inject-pod: ## Plant the prompt-injection pod (needs create-pod access)
	kubectl apply -f attack/injected-pod.yaml

.PHONY: inject-logs
inject-logs: ## Poison the agent's logs over HTTP (needs no cluster access)
	@echo "Port-forward the service first:"
	@echo "  kubectl -n $(NAMESPACE) port-forward svc/parcel-tracker-parcel-tracker 8080:80"
	bash attack/inject-via-logs.sh

.PHONY: clean-injection
clean-injection: ## Remove the injected pod and flush poisoned logs
	-kubectl delete -f attack/injected-pod.yaml
	-kubectl -n $(NAMESPACE) rollout restart deploy/parcel-tracker-parcel-tracker

.PHONY: break
break: ## Reset values.yaml to the broken 64Mi limit
	@sed -i.bak 's/^    memory: 256Mi$$/    memory: 64Mi/' chart/values.yaml && rm -f chart/values.yaml.bak
	@grep -n -A2 'limits:' chart/values.yaml

.PHONY: fix
fix: ## Apply the correct 256Mi limit by hand (the agent should do this instead)
	@sed -i.bak 's/^    memory: 64Mi$$/    memory: 256Mi/' chart/values.yaml && rm -f chart/values.yaml.bak
	@grep -n -A2 'limits:' chart/values.yaml
