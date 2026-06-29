# KADM Bootstrap And GitOps Design

Date: 2026-06-27

## Goal

Reduce KADM installation and daily usage to three operator-facing entrypoints:

1. Server-side bootstrap:
   `curl -fsSL <install-kadm.sh> | bash -s -- prepare`
   `curl -fsSL <install-kadm.sh> | bash -s -- deploy`
   or one-shot:
   `curl -fsSL <install-kadm.sh> | bash -s -- all`
2. Client-side setup:
   `curl -fsSL <install-kadm-client.sh> | bash`
3. Day-2 operations:
   `kadmctl ...`

The bootstrap path must not depend on preinstalled KADM tools. `kadmctl` is a post-bootstrap operator tool, not the first-install entrypoint.

## Repository Model

KADM uses four repositories with strict boundaries.

- `kadm-platform-assets`
  Owns offline artifacts only.
  Contents:
  - pinned manifests and chart tarballs
  - K3s binaries and checksums
  - optional image bundles for platform components
  - bundle metadata and checksums
  - CI workflows that download, package, and publish offline bundles

- `kadm-platform-system`
  Owns bootstrap scripts, system deployment logic, and platform-level GitOps definitions.
  Contents:
  - `bootstrap/install-kadm.sh`
  - `bootstrap/install-kadm-client.sh`
  - self-hosted and managed-k8s deployment profiles
  - Argo CD, Argo Rollouts, Cilium/Gateway profiles
  - release-console deployment entrypoint
  - operator docs

- `kadm-release-console`
  Owns the release console code only.
  Contents:
  - Web and API code
  - release orchestration logic
  - cluster connect/status logic
  - release-console container image build workflow
  It does not own application deployment manifests.

- `kadm-app-configs`
  Owns application GitOps desired state and registry metadata.
  Contents:
  - `apps/apps.json`
  - `apps/<app>/base/*`
  - `apps/<app>/overlays/<env>/*`
  - app-specific secret examples
  Application source repositories do not contain production deployment YAML.

## Operator Experience

### 1. Server Bootstrap

`install-kadm.sh` supports:

- `prepare`
  Downloads the selected bundle from `kadm-platform-assets`, verifies checksums, expands assets locally, and imports packaged images if present.
  This is the only phase allowed to require outbound network access.

- `deploy`
  Uses only local prepared assets.
  Responsibilities:
  - self-hosted mode: install K3s from local bits
  - managed-k8s mode: skip K3s bootstrap
  - install platform components from local assets
  - install `kadm-release-console`
  - register `kadm-app-configs`
  - configure DNS overrides if required
  - write cluster profile and kubeconfig handoff data

- `all`
  Executes `prepare` then `deploy`.

### 2. Client Setup

`install-kadm-client.sh` supports:

- install `kadmctl`
- fetch cluster profile and kubeconfig from the primary access host
- write:
  - `~/.kadm`
  - `~/.kube/kadm/<cluster>.yaml`
- migrate legacy local state from:
  - `~/.onecd`
  - `~/.kube/onecd`

### 3. Day-2 Operations

`kadmctl` remains for post-bootstrap tasks:

- `connect`
- `status`
- `cleanup-legacy-onecd`
- `publish-release-console`
- `configure-demo-apps`
- future:
  - `upgrade`
  - `backup`
  - `join`

## Deployment Modes

### Self-Hosted K3s

`deploy` does all of the following:

1. install K3s control plane on the first node
2. install Cilium and Gateway API from local assets
3. install Argo CD and Argo Rollouts
4. deploy `kadm-release-console`
5. register app configs from `kadm-app-configs`
6. optionally generate join scripts for later worker/master expansion

### Managed Kubernetes

`deploy` skips K3s installation and assumes a valid kubeconfig already exists.

It still performs:

1. DNS and cluster capability validation
2. platform component deployment
3. release-console deployment
4. app-configs registration

The system profile must avoid assuming Cilium or self-hosted Gateway in managed environments unless explicitly enabled.

## GitOps Model

### System GitOps

`kadm-platform-system` owns platform-level desired state:

- Argo CD installation
- Argo Rollouts installation
- release-console Argo CD `Application`
- shared platform namespaces and RBAC

### Application GitOps

`kadm-app-configs` owns application desired state:

- `apps/demo-hello/overlays/prod`
- `apps/demo-hello-spring/overlays/prod`
- future application directories

Argo CD `Application` resources for applications must point to `kadm-app-configs`, not to source repositories.

## Release Flow

The release flow is:

1. release-console triggers the application source repository workflow
2. source repository workflow builds and pushes the application image
3. release-console updates the corresponding `kadm-app-configs` `kustomization.yaml`
4. release-console triggers Argo CD sync
5. release-console waits for Rollout to reach a canary pause point
6. operator explicitly triggers promote

This preserves the rule that production deployment YAML stays in `kadm-app-configs`, not in application source repositories.

## Offline Requirements

The platform install path must be offline-first after `prepare`.

Required bundle contents for the first implementation:

- K3s installer assets
- Gateway API experimental manifest
- Argo CD install manifest
- Argo Rollouts install manifest
- Cilium chart tarball

Required follow-up bundle contents:

- platform container images
- optional release-console image
- optional app base images if a fully disconnected environment is a target

## DNS And External Dependency Policy

Deployment must not silently depend on cluster DNS working with arbitrary upstream resolvers.

`deploy` must validate:

- pod DNS resolution to GitHub endpoints if GitOps uses public GitHub
- pod egress to GitHub and GHCR

If validation fails, `deploy` must:

- fail clearly, or
- apply an explicit DNS override profile

This is a platform responsibility, not an application responsibility.

## Demo Dependency Policy

Demo dependencies are not part of the generic production interface.

`configure-demo-apps` remains a separate post-deploy command for this repository set because:

- it is specific to `demo-hello` and `demo-hello-spring`
- it encodes MySQL user and secret conventions
- it should not be baked into the generic KADM installation contract

## Directory Convention

Recommended `kadm-platform-system` layout:

```text
bootstrap/
  install-kadm.sh
  install-kadm-client.sh
profiles/
  self-hosted/
  managed-k8s/
templates/
bin/
tests/
docs/
```

Recommended `kadm-app-configs` layout:

```text
apps/
  apps.json
  demo-hello/
    base/
    overlays/prod/
  demo-hello-spring/
    base/
    overlays/prod/
```

## Migration Rules

The old `onecd` naming is legacy only.

- cluster resources should use `kadm`
- local state should use `~/.kadm` and `~/.kube/kadm`
- `ONECD_*` environment variables remain temporary compatibility aliases only

The old `onecd` namespace and Argo CD application are removable after cluster migration validation.

## Open Follow-Ups

These are the next implementation steps implied by this design:

1. add `bootstrap/install-kadm.sh`
2. add `bootstrap/install-kadm-client.sh`
3. move first-install logic out of `kadmctl`
4. move platform asset publication from artifact-only to a stable downloadable bundle channel
5. add explicit DNS validation and override handling in `deploy`
