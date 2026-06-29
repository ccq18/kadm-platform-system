# OneCD Release System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Initialize the empty OneCD release-system repository and two application repositories so Argo CD can read GitHub source directly, GitHub Actions can build images, and Argo Rollouts can run canary releases for `hello` and `hellospring`.

**Architecture:** Each application repository owns its source, Dockerfile, GitHub Actions workflow, and Argo CD-ready Kubernetes manifests under `k8s/overlays/prod`. OneCD is a small Node.js web/API service that triggers GitHub Actions builds, calls Argo CD sync/status APIs, and reads or patches Rollout CRDs through the Kubernetes API. Runtime secrets stay outside Git.

**Tech Stack:** Node.js 20, Express, native `fetch`, GitHub Actions, GHCR, Argo CD Applications, Argo Rollouts CRDs, Kustomize manifests.

---

### Task 1: Initialize Local Checkouts

**Files:**
- Clone: `git@github.com:ccq18/onecd.git`
- Clone: `git@github.com:ccq18/demo-hello.git`
- Clone: `git@github.com:ccq18/demo-hello-spring.git`

- [ ] Clone the three empty repositories as siblings of the current `k3s` checkout.
- [ ] Confirm each repository has no commits.

### Task 2: Build `demo-hello`

**Files:**
- Create: `demo-hello/src/server.js`
- Create: `demo-hello/public/index.html`
- Create: `demo-hello/public/styles.css`
- Create: `demo-hello/public/app.js`
- Create: `demo-hello/package.json`
- Create: `demo-hello/package-lock.json`
- Create: `demo-hello/Dockerfile`
- Create: `demo-hello/k8s/base/*.yaml`
- Create: `demo-hello/k8s/overlays/prod/kustomization.yaml`
- Create: `demo-hello/.github/workflows/build-and-publish.yaml`
- Create: `demo-hello/docs/*.md`

- [ ] Copy the existing Node CRUD application source from `k3s/hello`.
- [ ] Convert the Kubernetes workload from `Deployment` to an Argo Rollouts `Rollout`.
- [ ] Keep the `apps` namespace, `hello-db` Secret reference, `ghcr-cred` pull secret, and `hello.ai47.cc` Ingress host.
- [ ] Add GitHub Actions to run `npm ci`, build `ghcr.io/ccq18/demo-hello`, push SHA tags, and update the prod Kustomize image tag.
- [ ] Document local development, CI, Argo CD Application creation, and Rollouts operations.

### Task 3: Build `demo-hello-spring`

**Files:**
- Create: `demo-hello-spring/src/main/**`
- Create: `demo-hello-spring/pom.xml`
- Create: `demo-hello-spring/Dockerfile`
- Create: `demo-hello-spring/k8s/base/*.yaml`
- Create: `demo-hello-spring/k8s/overlays/prod/kustomization.yaml`
- Create: `demo-hello-spring/.github/workflows/build-and-publish.yaml`
- Create: `demo-hello-spring/docs/*.md`

- [ ] Copy the existing Spring Boot CRUD application source from `k3s/hellospring`, excluding `target`.
- [ ] Convert the Kubernetes workload from `Deployment` to an Argo Rollouts `Rollout`.
- [ ] Keep the `apps` namespace, `hellospring-db` Secret reference, `ghcr-cred` pull secret, and `hellospring.ai47.cc` Ingress host.
- [ ] Add GitHub Actions to run Maven tests/package, build `ghcr.io/ccq18/demo-hello-spring`, push SHA tags, and update the prod Kustomize image tag.
- [ ] Document local development, CI, Argo CD Application creation, and Rollouts operations.

### Task 4: Build `onecd`

**Files:**
- Create: `onecd/package.json`
- Create: `onecd/src/**/*.js`
- Create: `onecd/public/**/*`
- Create: `onecd/config/apps.example.json`
- Create: `onecd/k8s/base/*.yaml`
- Create: `onecd/docs/*.md`
- Create: `onecd/.env.example`
- Create: `onecd/README.md`

- [ ] Add API endpoints to list applications, trigger GitHub Actions builds, query Argo CD Application state, trigger Argo CD sync, read Rollout status, and request promote/abort/restart through Kubernetes CRD annotations.
- [ ] Add a compact web UI for the two applications with build, sync, and rollout controls.
- [ ] Add focused tests for configuration loading, GitHub workflow dispatch request construction, Argo CD request construction, and Kubernetes Rollout patch construction.
- [ ] Document required tokens, service account permissions, local development, and cluster deployment.

### Task 5: Verify And Push

**Files:**
- Verify all created repositories.

- [ ] Run `npm test` and `npm run lint` in `onecd`.
- [ ] Run `npm ci` and at least syntax/startup checks in `demo-hello`.
- [ ] Run `mvn test` in `demo-hello-spring` if Maven is available.
- [ ] Run `kubectl kustomize` or `kustomize build` for both application overlays if the tool is available.
- [ ] Commit and push each repository to GitHub.
