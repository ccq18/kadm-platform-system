# Architecture

KADM Release Console is a small release console for two GitOps-managed demo applications. The UI presents two main release actions:

- Publish: trigger build, deploy the produced GitOps change, and wait for canary check.
- Promote: explicitly advance the current candidate version.

```text
Browser
  |
KADM Release Console API
  |-- GitHub Actions API: workflow_dispatch and workflow run status
  |-- Argo CD API: Application status and sync
  |-- Kubernetes API: Argo Rollouts CRD status and patches
  |
K3s
  |-- Argo CD Applications read GitHub repositories
  |-- Argo Rollouts manages canary releases
```

Argo CD reads these GitHub paths:

- `https://github.com/ccq18/kadm-app-configs.git`, path `apps/demo-hello/overlays/prod`
- `https://github.com/ccq18/kadm-app-configs.git`, path `apps/demo-hello-spring/overlays/prod`

The application repositories own their source, Dockerfile, build workflow, and image outputs. `kadm-app-configs` owns Kubernetes delivery manifests. KADM Release Console orchestrates the release but does not write manifests directly.

Publish tasks are runtime-only state held in the KADM Release Console process. This is intentional for the first version: losing a task on restart is acceptable because stable traffic changes only when an operator explicitly promotes a candidate. After restart, KADM Release Console derives the visible state from GitHub workflow runs, Argo CD application status, and Argo Rollouts status.

Version hints are derived from Rollout status fields such as `stableRS` and `currentPodHash`. Candidate promotion is a Rollouts runtime action. Retained historical versions are released through GitOps: KADM extracts the retained ReplicaSet image tag, updates the app manifest in `kadm-app-configs`, syncs Argo CD, waits for the canary or blue-green check, then requires an explicit promote.

Rollout `promote`, `promote-full`, and `abort` actions are implemented as Kubernetes API merge patches against the Rollout status subresource. Normal `promote` clears the current pause; `promote-full` is explicit and skips the remaining pause/check steps. If a future Argo Rollouts version or cluster policy rejects direct status patches, keep the same KADM Release Console API surface and swap the backend action implementation to Argo CD resource actions or a small internal gateway that runs the official `kubectl argo rollouts` plugin.
