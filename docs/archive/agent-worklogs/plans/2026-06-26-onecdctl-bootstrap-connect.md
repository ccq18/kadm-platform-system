# onecdctl Bootstrap And Connect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local `onecdctl` installer CLI with safe `bootstrap` and `connect` workflows.

**Architecture:** `onecdctl` is a Bash CLI under `ops/platform/bin/`. It keeps remote-changing operations behind `--apply`, stores a local cluster profile, rewrites kubeconfig to a localhost tunnel endpoint, and uses `ssh` plus `kubectl port-forward` for console access.

**Tech Stack:** Bash, SSH, kubectl, local shell tests.

---

### Task 1: CLI Tests

**Files:**
- Create: `ops/platform/tests/onecdctl_test.sh`

- [x] Write tests for bootstrap dry-run, bootstrap apply with stubbed ssh, and connect dry-run.
- [x] Run tests before implementation and confirm they fail because `ops/platform/bin/onecdctl` does not exist.

### Task 2: onecdctl CLI

**Files:**
- Create: `ops/platform/bin/onecdctl`
- Modify: `ops/platform/README.md`

- [x] Implement command parsing for `bootstrap`, `connect`, and `help`.
- [x] Implement `bootstrap` dry-run output.
- [x] Implement `bootstrap --apply` first-node K3s install command, kubeconfig retrieval, local kubeconfig rewrite, and cluster profile writing.
- [x] Implement `connect --dry-run` command preview.
- [x] Implement foreground `connect` with SSH tunnel and OneCD port-forward.
- [x] Document the two-command workflow.

### Task 3: Verification

**Files:**
- `ops/platform/bin/onecdctl`
- `ops/platform/tests/onecdctl_test.sh`

- [x] Run `bash -n ops/platform/bin/onecdctl ops/platform/tests/onecdctl_test.sh`.
- [x] Run `ops/platform/tests/onecdctl_test.sh`.
- [x] Run `ops/platform/bin/onecdctl --help`.
