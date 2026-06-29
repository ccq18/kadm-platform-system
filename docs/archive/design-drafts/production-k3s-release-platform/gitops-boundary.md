# GitOps Boundary And Current OneCD Release Model

**Date**: 2026-06-26  
**Status**: Draft  
**Scope**: Production Kubernetes application delivery platform target

## Purpose

This note records two decisions for the next design step:

- The current K3s cluster is a test cluster and may be rebuilt directly according to the new fixed growth path.
- The current phase keeps the existing OneCD release model: `Build -> Sync -> Promote / Abort`.

It also defines what GitOps replaces in this project, and what it does not replace.

GitOps is an internal delivery mechanism, not the primary product surface for ordinary developers. The product surface should speak in terms of applications, environments, versions, configuration, domains, logs, releases, and rollbacks. Kubernetes objects and GitOps resources remain the source of truth and advanced-mode evidence.

## Current Decisions

### Rebuild The Test Cluster

The current `1 master + 2 worker` cluster does not need in-place migration. The implementation plan may clear and rebuild it to validate the product growth path:

```text
1 Server with embedded etcd
  -> 3 Server HA
  -> optional Worker expansion
```

If speed matters for a test run, the team may still create the final three-server shape directly, but the product design must keep the one-server start and `1 -> 3` HA upgrade as the primary user path.

Keep as reusable assets:

- Repository code and documentation.
- The `onecd`, `demo-hello`, and `demo-hello-spring` repository layout.
- GitHub Actions build flow.
- GHCR image publishing.
- Argo CD and Argo Rollouts release-chain experience.

Recreate as cluster state:

- K3s nodes and node roles, including the single-node start state and later HA node set.
- The default self-hosted cluster resources, including Cilium and Cilium Gateway entrypoint deployment.
- Argo CD installation.
- Argo Rollouts installation.
- OneCD deployment.
- Demo application deployments.
- Kubernetes Secrets, ServiceAccounts, RBAC, Services, Gateways, and HTTPRoutes.

Before rebuilding, explicitly decide whether any test data, such as local MySQL data on the old worker node, needs to be exported.

### Keep Current OneCD Flow

The current phase keeps OneCD as a thin release console:

```text
OneCD
  -> GitHub Actions workflow_dispatch
  -> GitHub Actions build image and push GHCR
  -> GitHub Actions update app repository k8s/overlays/prod
  -> OneCD or operator triggers Argo CD sync
  -> Argo CD syncs Kubernetes objects
  -> Argo Rollouts runs canary
  -> OneCD or operator promotes or aborts
```

The current phase does not add a production portal database, release ticket model, approval workflow, notification center, release lock, or persistent audit tables. Those remain later enhancements.

The current phase also keeps the existing repository boundary:

- `onecd`
- `demo-hello`
- `demo-hello-spring`

Splitting into dedicated infrastructure, platform GitOps, application GitOps, and source repositories remains a later governance improvement.

## What GitOps Replaces

GitOps replaces direct writes to the production Kubernetes cluster by humans, CI jobs, or release portals.

| Direct-cluster approach | GitOps approach |
| --- | --- |
| CI runs `kubectl apply` against production. | CI updates Git desired state; Argo CD syncs it. |
| CI runs `helm upgrade` against production. | CI updates chart version or values in Git; Argo CD syncs it. |
| Operator runs `kubectl set image`. | Operator or automation updates image tag or digest in Git. |
| Someone edits live Kubernetes YAML manually. | Change is reviewed and committed to Git. |
| Rollback means manually changing live objects again. | Rollback means Git revert or restoring a previous image digest, then syncing. |
| The live cluster is treated as the source of truth. | Git stores desired state; the cluster is actual state. |

In short:

```text
Before GitOps:
  kubectl / helm / portal writes directly to the cluster

With GitOps:
  Git records desired state
  Argo CD reconciles the cluster to that state
```

Product flow:

```text
Developer chooses application, environment, version, config, and domain
  -> platform updates Git desired state
  -> Argo CD reconciles Kubernetes objects
  -> platform translates rollout and health signals into user-facing status
```

Cluster growth should not change this flow:

```text
1 Server
  -> 3 Server HA
  -> 3 Server + N Worker

Application release model stays:
  Build -> Sync -> Promote / Abort
```

## What GitOps Does Not Replace

GitOps does not replace the surrounding systems. It defines how desired state reaches Kubernetes.

| Component | Still responsible for |
| --- | --- |
| GitHub Actions | Test, build, scan, push image, and update Git desired state. |
| Git repository | Store desired Kubernetes state, such as Kustomize overlays and image references. |
| Argo CD | Compare Git desired state with cluster actual state and sync changes. |
| Argo Rollouts | Manage canary or blue-green release state and progressive delivery actions. |
| Gateway API implementation | Route external HTTP/HTTPS traffic from Gateway listeners to HTTPRoute backends. The default self-hosted path uses Cilium Gateway API. |
| OneCD / product portal | Provide the application delivery UI/API for build, sync, status, promote, abort, restart, diagnostics, and advanced Kubernetes evidence. |
| Kubernetes | Run workloads and store actual runtime objects. |
| Terraform or cloud tooling | Manage cloud resources outside the cluster, such as VPC, ECS, load balancers, DNS, object storage, and databases. |
| Secret management | Provide credentials without committing plaintext secrets to Git. |
| Monitoring and logging | Observe runtime behavior, alert, and support incident analysis. |

## Current Phase Ownership

```text
Developer
  -> push code
GitHub Actions
  -> test/build/push image
  -> update app repository k8s/overlays/prod
Argo CD
  -> sync desired state from Git to Kubernetes
Argo Rollouts
  -> create canary ReplicaSet and manage release state
Gateway API implementation
  -> route external HTTP/HTTPS traffic to Kubernetes Services
OneCD
  -> trigger build/sync/action, display product status, and expose advanced evidence
```

OneCD is a control surface, not the source of truth for deployed versions. The deployed version must remain recoverable from Git, Argo CD Application state, Rollout CRD state, and Kubernetes objects.

Precise percentage-based external traffic shifting is a network-design topic under `network-architecture.md`. The current phase keeps OneCD as the release control surface, while the system design stage must decide whether Gateway API and the default Cilium Gateway implementation can provide the required Rollouts traffic integration or whether the first phase uses a simpler rollout model.

## Product Surface Boundary

Ordinary developers should not need to understand the GitOps and Kubernetes object graph to complete a release.

User-facing language:

```text
Application
Environment
Version
Configuration
Domain
Logs
Release
Rollback
```

Internal desired state and advanced evidence:

```text
Kustomize overlay
Argo CD Application
Rollout or Deployment
Service
Gateway
HTTPRoute
NetworkPolicy
ConfigMap
Secret reference
Pod
Event
```

The portal may show the internal objects in advanced mode, but the default release path should present a diagnosis-oriented product status, such as:

```text
Application cannot start
Reason: insufficient cluster memory
Evidence: Pod Pending, scheduler reports 0/3 nodes available
Suggested actions: lower memory request, add a node, or stop unused workloads
```

This translation layer is part of the product value and should not be delegated to raw Kubernetes YAML alone.

## Guardrails

- GitHub Actions must not store production kubeconfig.
- GitHub Actions must not directly run production `kubectl apply`, `helm upgrade`, `kubectl set image`, or equivalent direct mutation commands.
- Permanent version changes must be represented in Git.
- `Abort` is an emergency traffic action; permanent rollback must update Git desired state.
- The default application templates should emit standard Kubernetes and Gateway API resources whenever possible.
- Provider-specific resources, such as CiliumNetworkPolicy or CiliumEnvoyConfig, belong in internal cluster-profile directories or advanced plugins, not in ordinary application templates.
- Secrets, kubeconfig files, node tokens, SSH keys, database passwords, and object-storage credentials must not be committed to Git.
- OneCD must not be exposed publicly before authentication, HTTPS, authorization, and an access policy are in place.
- If OneCD keeps direct Kubernetes Rollout patch permissions in the current phase, RBAC should be restricted to the target namespace and the minimum required Rollout actions.

## Rollback Boundary

Emergency rollback:

```text
OneCD or operator triggers Abort
  -> Argo Rollouts returns traffic to stable
  -> Business traffic recovers quickly
```

Permanent rollback:

```text
Git revert or restore previous image digest
  -> Argo CD syncs desired state
  -> Argo Rollouts reconciles release state
  -> Git again matches the intended production version
```

Do not rely on `Abort` alone as the final rollback, because Git may still point to the bad version.

## Later Enhancements

Later phases may add:

- GitOps PR approval workflow.
- Portal database.
- Release tickets.
- Persistent audit records.
- Release locks.
- Notifications.
- Diagnosis rule engine for Kubernetes events, scheduling failures, image pull failures, probe failures, certificate expiry, node pressure, and rollout stalls.
- Two-mode UI with ordinary application lifecycle mode and advanced Kubernetes operations mode.
- Full productized node preflight, `1 -> 3` HA upgrade workflow, Worker scale-out workflow, controlled workload rebalance, and failed-node replacement workflow if they are not completed in the first implementation slice.
- Separate infrastructure, platform GitOps, application GitOps, and application source repositories.
- Argo CD Resource Actions or a restricted internal gateway for Rollout actions instead of direct Kubernetes Rollout patches from OneCD.

## Evidence

- Current cluster topology and K3s defaults: `docs/cluster-overview.md`.
- Current deployment record: `docs/deployment-2026-06-25.md`.
- Current OneCD release chain and access model: `docs/onecd-release-system.md`.
- Current target spec: `docs/design-docs/platform/production-k3s-release-platform/spec.md`.
- Current target network architecture: `docs/design-docs/platform/production-k3s-release-platform/network-architecture.md`.
