# agentic-gitops-demo

An AI agent with read-only access to an EKS cluster diagnoses a failing
workload and proposes the fix as a pull request. Everything the agent reads to
do that — pod annotations, events, logs — is writable by someone who is not
you. This repository shows what happens when it is.

Two stories run on the same stack:

1. **The happy path.** The agent finds an OOMKill whose root cause is in Helm
   values, opens a PR that *removes* the memory limit, the policy gate rejects
   it, the agent corrects the PR, and Argo CD syncs the merge.
2. **The attack** ([`attack/`](attack/)). A pod annotation — or a plain HTTP
   request that lands in the service's logs — carries a forged incident note.
   The agent reads it while triaging and opens a PR that smuggles a registry
   swap, citing the incident because it believes it. A deterministic policy
   catches it; prompt hardening measurably does not.

Built as the live demo for a KubeCon Security session on prompt injection
through the Kubernetes state an agent trusts. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for how the controls fit
together, [`attack/README.md`](attack/README.md) for the injection vectors, and
[`docs/DEMO_SCRIPT.md`](docs/DEMO_SCRIPT.md) for the stage runbook.

## Layout

| Path | What it is |
| --- | --- |
| [`app/`](app/) | `parcel-tracker`, a small Go service that OOM-kills itself under the chart's default memory limit |
| [`chart/`](chart/) | The Helm chart Argo CD reconciles. The planted defect lives in `values.yaml`. |
| [`argocd/`](argocd/) | `AppProject`, `Application`, and the agent's read-only RBAC |
| [`policy/`](policy/) | Kyverno policies — the gate, run both in CI and at admission |
| [`agent/`](agent/) | The triage agent. Three tools; only one of them writes anything. `--hardened` adds provenance defenses. |
| [`attack/`](attack/) | Two prompt-injection vectors and what catches them |
| [`.github/workflows/`](.github/workflows/) | The policy gate on every pull request |
| [`infra/`](infra/) | Terraform: the EKS Auto Mode cluster, ECR, Argo CD (Helm), and Kyverno (Helm) |

## Prerequisites

- AWS credentials with permission to create a VPC, an EKS cluster, and ECR
- `terraform` 1.6+, `kubectl`, `helm` 3.16+, `docker` with buildx, `gh`, `kyverno` CLI, `aws` CLI
- `ANTHROPIC_API_KEY` in the environment
- A GitHub repository you can push branches to (the agent opens PRs against it)

You do **not** need an existing cluster — `make infra` creates one.

## Where the agent runs

The agent runs **on your machine**, not in the cluster. `agent/triage_agent.py`
is a local process that:

- calls the **Anthropic API** for the reasoning — which commands to run, how to
  read the output, what the fix is, and (in the attack) whether to believe what
  it read. This is the agent. `ANTHROPIC_API_KEY` is required because the model
  is the part that thinks.
- reaches the cluster read-only through your **`kubectl`** context.
- opens pull requests by shelling out to **`git`** and **`gh`** against a local
  clone, using the credentials already on the machine.

So the model decides; `kubectl`, `git`, and `gh` are the hands that carry the
decision out. Nothing runs in-cluster, and the only thing that writes anywhere
is a pull request. (In production you would run the agent as its own scoped
GitHub App with no merge rights, rather than borrowing your `gh` token — see
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).)

## Setup

Run once, before the demo. Steps 1–6 take ~25 minutes, most of it the cluster.

```bash
# 0. Environment and auth
export ANTHROPIC_API_KEY=...
aws sts get-caller-identity          # AWS creds resolve
gh auth status                       # gh logged in to the account that opens PRs

# 1. Push this repo to GitHub — the agent opens PRs against it
git init && git add -A && git commit -m "initial"
gh repo create agentic-gitops-demo --public --source=. --push

# 2. Cluster (EKS Auto Mode) + ECR + Argo CD + Kyverno, in one apply.
#    Edit infra/variables.tf first to restrict the API endpoint to your IP.
make infra                           # ~15-20 min
make kubeconfig                      # point kubectl at the new cluster

# 3. Wire the placeholders to real values, then push
#    chart/values.yaml       -> image.repository = terraform's ecr_repository_url
#    argocd/appproject.yaml  -> spec.sourceRepos = your repo URL
#    argocd/application.yaml -> spec.source.repoURL = your repo URL
git commit -am "wire up repo and registry" && git push

# 4. Build and push the image
make image TAG=v1

# 5. Policies, Argo CD Application, project, and agent RBAC
#    (Kyverno and Argo CD themselves came from `make infra`)
make argocd

# 6. Confirm the broken starting state, and open the Argo CD UI
make status                          # pods CrashLoopBackOff / OOMKilled
make argocd-url                      # UI over HTTP (no cert) + admin password
```

`make infra` installs Argo CD in **insecure mode** behind an internet-facing NLB
and hands you its DNS name — no TLS certificate needed. Appropriate for a
throwaway demo cluster and nothing else. Tear the whole thing down afterward
with `make destroy` so the AWS bill stops.

Within a minute or two of step 5, pods should be `CrashLoopBackOff` with
`Reason: OOMKilled`. That is the intended starting state — the demo begins
broken.

## Running the demo

Once setup is done, the demo is two acts. The detailed stage runbook —
timing, fallbacks, terminal layout — is in [`docs/DEMO_SCRIPT.md`](docs/DEMO_SCRIPT.md).

**Act one — the agent works, the gate works:**

```bash
make status          # show the broken pods and Argo CD Degraded
make agent           # agent opens a PR -> gate rejects -> corrected PR -> merge -> sync
```

**Act two — the same agent, turned by data anyone can write:**

```bash
make inject-pod      # plant the forged incident in a pod annotation
#   OR, needing zero cluster access — just an HTTP request:
#   kubectl -n parcel-tracker port-forward svc/parcel-tracker-parcel-tracker 8080:80 &
#   make inject-logs

make agent           # agent reads the forged note, opens a poisoned PR
```

The deterministic catch fires on the **pull request**, not locally: GitHub
Actions runs the policy gate on the agent's branch and posts the failure comment
(`require-trusted-registry`). Show that in the browser — it is the moment of the
talk. To reproduce it locally, check out the agent's branch first, because
`make policy` renders whatever tree is currently checked out:

```bash
git fetch origin && git checkout <the-agent-branch>   # e.g. agent/...
make policy          # require-trusted-registry FAILS
git checkout main
```

Then the prompt-hardening beat:

```bash
make agent-hardened  # provenance defenses on... still fooled on an unseen payload
```

**Reset between run-throughs:**

```bash
make clean-injection # remove the injected pod, flush poisoned logs
make break           # restore the broken 64Mi limit
```

`make agent-dry-run` diagnoses without offering the pull-request tool, if you
want to show the reasoning without a write.

The agent's tool surface is deliberately small:

| Tool | Access |
| --- | --- |
| `kubectl` | Read verbs only (`get`, `describe`, `logs`, `top`, `events`), enforced by an allowlist in Python before any subprocess runs |
| `read_repo_file` | Read files inside this repository |
| `open_pull_request` | Edit one file on a branch and open a PR — the only write path anywhere in the agent |

There is no tool that syncs an Argo CD application, patches a Deployment, or
applies a manifest. If you run the Argo CD MCP server alongside this, set
`MCP_READ_ONLY=true` so its write tools are never registered.

## The policy gate

The Kyverno policies in `policy/` run in two places against the same rules:

- **In CI** on every pull request touching `chart/`, `policy/`, or `argocd/` —
  the chart is rendered with `helm template` and checked with `kyverno apply`.
  A failure is posted back as a PR comment, which is what the agent reads.
- **In the cluster** as `ClusterPolicy` resources in `Enforce` mode, so the
  check still holds if CI is bypassed.

Run the same check locally. `make policy` renders the chart from **whatever is
currently checked out**, so to reproduce a PR's result, check out that branch
first:

```bash
make policy          # checks the current working tree
# to check an agent's proposed change:
git checkout <agent-branch> && make policy && git checkout main
```

| Policy | Catches |
| --- | --- |
| `require-resource-limits` | "Fixing" an OOMKill by deleting the limit instead of raising it |
| `disallow-debug-escalation` | Privileged containers, host namespaces, and `hostPath` mounts added "temporarily for debugging" |
| `require-trusted-registry` | Images from outside the account's ECR, and `:latest` |
| `restrict-rbac-escalation` | An agent widening its own permissions through a merged PR |

## Resetting

```bash
make break    # restore the 64Mi limit
```

Then commit and merge that, and let Argo CD sync the broken state back. The
full reset sequence, including closing leftover agent branches, is in
[`docs/DEMO_SCRIPT.md`](docs/DEMO_SCRIPT.md).
