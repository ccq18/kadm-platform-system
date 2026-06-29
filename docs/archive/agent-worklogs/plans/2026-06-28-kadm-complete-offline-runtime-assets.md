# KADM Complete Offline Runtime Assets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade KADM bootstrap so scope-A install/runtime dependencies can be restored from `kadm-platform-assets.tgz` and runtime images are imported directly into K3s containerd.

**Architecture:** Extend the asset bundle with metadata, cached tools, cached repos, and a compressed runtime image archive. `kadmctl import-assets` records bundle metadata, `install-tools` prefers cached Helm, `deploy` imports runtime images after K3s starts, and `install-kadm.sh prepare` can restore workspace repos from the bundle before falling back to GitHub.

**Tech Stack:** Bash, tar, zstd, K3s containerd (`k3s ctr`), Docker-compatible image export in the asset builder, existing shell test harness.

---

### Task 1: Complete Bundle Import Metadata

**Files:**
- Modify: `/Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/bin/kadmctl`
- Modify: `/Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/tests/kadmctl_test.sh`

- [ ] **Step 1: Add a failing import test**

Add a test that creates a format-2 bundle with `metadata/offline-bundle.env`, `cache/tools`, `cache/images`, and existing manifest/chart cache entries. Assert `kadmctl import-assets` restores the files and persists metadata under `~/.kadm/cache/metadata/offline-bundle.env`.

- [ ] **Step 2: Run the import test and confirm it fails**

Run: `bash /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/tests/kadmctl_test.sh`
Expected: FAIL because `import-assets` does not yet restore metadata or validate complete bundle files.

- [ ] **Step 3: Implement metadata-aware import**

Update `cmd_import_assets` to accept bundles containing `cache/` plus optional `metadata/`, extract both into `~/.kadm`, validate complete bundles contain `cache/tools`, `cache/images/runtime-images.tar.zst`, `cache/images/runtime-images.txt`, and `cache/repos`, and print whether the bundle is complete or partial.

- [ ] **Step 4: Run tests and confirm pass**

Run: `bash /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/tests/kadmctl_test.sh`
Expected: PASS.

### Task 2: Cached Helm Tool Install

**Files:**
- Modify: `/Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/bin/kadmctl`
- Modify: `/Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/tests/kadmctl_test.sh`

- [ ] **Step 1: Add a failing install-tools test**

Add a test that places `~/.kadm/cache/tools/helm-v3.15.4-linux-amd64.tar.gz`, stubs `tar`, and stubs `curl` to fail. Assert `kadmctl install-tools --apply` installs Helm from the cached archive and never calls `curl`.

- [ ] **Step 2: Run the install-tools test and confirm it fails**

Run: `bash /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/tests/kadmctl_test.sh`
Expected: FAIL because `install_helm` always downloads from `get.helm.sh`.

- [ ] **Step 3: Implement cached tool lookup**

Add `tool_cache_dir` and `helm_archive_cache_path`. Update `install_helm` so it uses the cached Helm archive when present, downloads only when missing, and refuses download if a complete offline bundle is active.

- [ ] **Step 4: Run tests and confirm pass**

Run: `bash /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/tests/kadmctl_test.sh`
Expected: PASS.

### Task 3: Runtime Image Import In Deploy

**Files:**
- Modify: `/Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/bin/kadmctl`
- Modify: `/Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/tests/kadmctl_test.sh`

- [ ] **Step 1: Add a failing deploy ordering test**

Extend the local deploy apply test so fake `sudo` records `zstd -dc ... | sudo k3s ctr -n k8s.io images import -` and image verification calls before Helm/Kubectl platform component installation.

- [ ] **Step 2: Run the deploy test and confirm it fails**

Run: `bash /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/tests/kadmctl_test.sh`
Expected: FAIL because deploy does not import runtime images.

- [ ] **Step 3: Implement runtime image import helpers**

Add helpers for runtime image paths, complete bundle detection, free-space warning, `import_runtime_images_if_available`, and `verify_runtime_images_present`. Call them after `install_local_k3s` and before `install_component_commands`.

- [ ] **Step 4: Run tests and confirm pass**

Run: `bash /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/tests/kadmctl_test.sh`
Expected: PASS.

### Task 4: Offline Workspace Repo Restore

**Files:**
- Modify: `/Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/bootstrap/install-kadm.sh`
- Modify: `/Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/tests/bootstrap_installers_test.sh`

- [ ] **Step 1: Add a failing prepare test for bundled repos**

Add a test bundle containing `cache/repos/kadm-platform-system.tgz` and `cache/repos/kadm-app-configs.tgz`. The `kadm-platform-system` archive contains `console/`. Stub `curl` to fail for repository downloads. Assert prepare restores both workspaces from the bundle and still imports assets.

- [ ] **Step 2: Run the bootstrap installer test and confirm it fails**

Run: `bash /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/tests/bootstrap_installers_test.sh`
Expected: FAIL because prepare downloads repos before importing the bundle.

- [ ] **Step 3: Implement bundle-first prepare**

Change `prepare_phase` to download the asset bundle first, import it, restore repos from `cache/repos` when present, and only call GitHub repo archive downloads for missing repos when the bundle is not complete.

- [ ] **Step 4: Run tests and confirm pass**

Run: `bash /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/tests/bootstrap_installers_test.sh`
Expected: PASS.

### Task 5: Complete Bundle Builder

**Files:**
- Modify: `/Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-assets/scripts/build-bundle.sh`
- Modify: `/Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-assets/versions/platform-assets.env`
- Modify: `/Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-assets/.github/workflows/build-offline-bundle.yaml`
- Modify: `/Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-assets/README.md`

- [ ] **Step 1: Add builder structure checks**

Use a dry-run/list mode in `build-bundle.sh` to verify the generated image list and intended bundle layout without pulling images. This keeps tests practical in normal development.

- [ ] **Step 2: Implement complete bundle build**

Add Helm download, repo archive download, image list generation, optional GHCR login, runtime image export to `runtime-images.tar.zst`, metadata generation, checksums, release-size warning, and no long-lived artifact upload.

- [ ] **Step 3: Update README and workflow**

Document complete offline scope, GHCR credential variables, expected bundle size, and Release-only publishing. Remove the full bundle artifact upload or reduce it to small metadata.

- [ ] **Step 4: Run shell syntax checks**

Run:
`bash -n /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-assets/scripts/build-bundle.sh`
`bash -n /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/bin/kadmctl`
`bash -n /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/bootstrap/install-kadm.sh`
Expected: all exit 0.

### Task 6: Final Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Run platform-system tests**

Run:
`bash /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/tests/kadmctl_test.sh`
`bash /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system/tests/bootstrap_installers_test.sh`
Expected: both pass.

- [ ] **Step 2: Run asset builder dry-run/list verification**

Run: `bash /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-assets/scripts/build-bundle.sh --list-images`
Expected: prints the generated runtime image list without pulling or saving images.

- [ ] **Step 3: Review diffs**

Run:
`git -C /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-system diff --stat`
`git -C /Users/lrd/mnt/homepc/data/homepcdata/k3s/kadm-platform-assets diff --stat`
Expected: only intended files are changed.
