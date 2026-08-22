# Argo CD resources

Apply in this order:

```bash
kubectl apply -f argocd/appproject.yaml
kubectl apply -f argocd/application.yaml
kubectl apply -f argocd/agent-rbac.yaml
```

## What each file is doing in the demo

**`appproject.yaml`** is the boundary. It pins the repository, the destination
namespace, and the exact kinds that may be created. `clusterResourceWhitelist`
is empty, so nothing merged into this repository can create a cluster-scoped
object — this is the backstop for the case where the policy gate is
misconfigured or skipped.

**`application.yaml`** turns on `automated` sync with `selfHeal: true`. This is
the part worth pausing on during the talk: self-heal means an out-of-band
`kubectl patch` is reverted on the next reconcile, whether a human or an agent
made it. It is what converts "the agent must not touch the cluster" from a
policy into a mechanism.

**`agent-rbac.yaml`** is the agent's identity in the cluster: read verbs on
pods, logs, events, and Deployments in one namespace. Combined with the
`read-only` Argo CD project role, the agent can fully diagnose an incident and
still has no way to act on its conclusion except by opening a pull request.

## Getting an Argo CD token for the agent

```bash
argocd proj role create-token parcel-tracker read-only --expires-in 24h
```

Store it as the `ARGOCD_API_TOKEN` repository secret. Set `MCP_READ_ONLY=true`
when running the Argo CD MCP server so the write-capable tools (`sync_application`,
`update_application`, `delete_application`, `run_resource_action`) are not even
registered — defence in depth against a prompt that talks the agent into trying.
