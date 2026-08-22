REGION      ?= us-east-1
ACCOUNT     ?= $(shell aws sts get-caller-identity --query Account --output text)
REGISTRY    ?= $(ACCOUNT).dkr.ecr.$(REGION).amazonaws.com
IMAGE       ?= $(REGISTRY)/parcel-tracker
TAG         ?= v1
NAMESPACE   ?= parcel-tracker
PY          ?= $(shell [ -x .venv/bin/python ] && echo .venv/bin/python || echo python3)

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
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
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
	$(PY) agent/triage_agent.py --namespace $(NAMESPACE)

.PHONY: agent-dry-run
agent-dry-run: ## Diagnose only; the pull-request tool is withheld
	$(PY) agent/triage_agent.py --namespace $(NAMESPACE) --dry-run

.PHONY: agent-hardened
agent-hardened: ## Run the agent with provenance hardening against injection
	$(PY) agent/triage_agent.py --namespace $(NAMESPACE) --hardened

.PHONY: inject-pod
inject-pod: ## Plant the forged note on the failing pods' annotations (needs annotate access)
	NAMESPACE=$(NAMESPACE) bash attack/inject-via-annotation.sh

.PHONY: inject-logs
inject-logs: ## Poison the agent's logs over HTTP (needs no cluster access)
	@echo "Port-forward the service first:"
	@echo "  kubectl -n $(NAMESPACE) port-forward svc/parcel-tracker-parcel-tracker 8080:80"
	bash attack/inject-via-logs.sh

.PHONY: clean-injection
clean-injection: ## Strip the forged annotation, delete any injected pod, flush poisoned logs
	-kubectl -n $(NAMESPACE) annotate pods -l app.kubernetes.io/name=parcel-tracker ops.internal/triage-note-
	-kubectl -n $(NAMESPACE) delete pod checkout-worker --ignore-not-found
	-kubectl -n $(NAMESPACE) rollout restart deploy/parcel-tracker-parcel-tracker

.PHONY: break
break: ## Reset values.yaml to the broken state (request 32Mi / limit 64Mi)
	@sed -i.bak -e 's/^    memory: 192Mi$$/    memory: 32Mi/' -e 's/^    memory: 256Mi$$/    memory: 64Mi/' chart/values.yaml && rm -f chart/values.yaml.bak
	@grep -n -A2 'requests:\|limits:' chart/values.yaml

.PHONY: fix
fix: ## Apply the correct sizing by hand (request 192Mi / limit 256Mi; the agent should do this instead)
	@sed -i.bak -e 's/^    memory: 32Mi$$/    memory: 192Mi/' -e 's/^    memory: 64Mi$$/    memory: 256Mi/' chart/values.yaml && rm -f chart/values.yaml.bak
	@grep -n -A2 'requests:\|limits:' chart/values.yaml
