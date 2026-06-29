# KADM Complete Offline Runtime Assets Design

Date: 2026-06-28
Status: Ready for user review

## Goal

Make the current KADM `install-kadm.sh all` path install and run without public network access after the offline bundle is available locally.

This design covers scope A only:

- K3s local install assets.
- Helm, manifests, and charts used by the installer.
- Runtime container images for the current platform components.
- Runtime container images for the current app configs.
- Source archives for the three bootstrap repositories consumed by the installer.

This design does not cover:

- Replacing GitHub Actions, GHCR, or public GitHub for future release publishing.
- Offline npm, Maven, or Docker build dependency resolution.
- Future apps that are not present in the selected `kadm-app-configs` bundle at build time.

## Current Problem

`kadm-platform-assets.tgz` currently contains K3s assets, manifests, and the Cilium chart, but it does not contain every runtime image referenced by those manifests and Kustomize overlays. A cluster can therefore install from local assets and still fail later when K3s needs to pull images from `quay.io`, `ghcr.io`, Docker Hub, or another registry.

The current installer also downloads GitHub repository archives and Helm in some paths. Those downloads must be removed from the complete offline install path.

## Recommended Approach

Use direct K3s containerd image import.

The offline bundle will include a compressed runtime image archive. After local K3s starts and before installing Cilium, Argo CD, Argo Rollouts, the release console, or demo apps, the installer decompresses and imports the archive into the K3s containerd namespace:

```bash
zstd -dc /path/to/runtime-images.tar.zst | sudo k3s ctr -n k8s.io images import -
```

Kubernetes manifests keep their original image names. For example, `quay.io/argoproj/argocd:v3.4.4` remains unchanged. The image exists in local containerd under the same reference before pods are created, so kubelet can resolve it from the local image store without pulling from the network.

This is the smallest reliable change for the current single-node installer. A local registry can be added later for multi-node scale-out, but it is not required for the first complete offline path.

## Bundle Format

The bundle remains a tarball named `kadm-platform-assets.tgz`, but its contents are expanded:

```text
cache/
  manifests/
  charts/
  k3s/
  tools/
    helm-v3.15.4-linux-amd64.tar.gz
  images/
    runtime-images.tar.zst
    runtime-images.txt
    runtime-images.sha256
  repos/
    kadm-platform-system.tgz
    kadm-app-configs.tgz
metadata/
  offline-bundle.env
  checksums.sha256
```

`metadata/offline-bundle.env` declares the compatibility contract:

```text
KADM_OFFLINE_BUNDLE_FORMAT=2
KADM_OFFLINE_COMPLETE=true
KADM_OFFLINE_IMAGE_IMPORT=containerd
KADM_OFFLINE_ARCH=linux-amd64
KADM_K3S_VERSION=v1.36.2+k3s1
KADM_CILIUM_VERSION=1.19.5
KADM_ARGOCD_VERSION=v3.4.4
KADM_ARGO_ROLLOUTS_VERSION=v1.9.0
```

Older bundles without `metadata/offline-bundle.env` can still be imported as partial bundles. They must not be treated as complete offline bundles.

## Image Inventory

The image inventory is generated during bundle build from the same inputs the installer uses:

- Argo CD manifest.
- Argo Rollouts manifest.
- Cilium chart rendered with the same Helm values used by `kadmctl`.
- `kadm-platform-system/console/k8s/overlays/prod`.

The current known image set includes:

- `quay.io/argoproj/argocd:v3.4.4`
- `quay.io/argoproj/argo-rollouts:v1.9.0`
- Cilium images rendered by chart `1.19.5`, including Cilium agent, operator, Envoy, certgen, and startup-script images.
- `ghcr.io/ccq18/kadm-release-console:sha-dd810af`

Business application images are intentionally outside the platform bundle. Fully offline application distribution needs a separate application image bundle.

The generated `runtime-images.txt` is the source of truth for import and validation. If an image is present in a rendered manifest but missing from `runtime-images.txt`, bundle build fails.

## Build Flow

`kadm-platform-assets/scripts/build-bundle.sh` becomes the complete bundle builder for `linux-amd64`.

It will:

1. Download the existing pinned assets: K3s install script, K3s binary, K3s airgap images, Gateway API manifest, Argo CD manifest, Argo Rollouts manifest, and Cilium chart.
2. Download Helm for `linux-amd64` into `cache/tools`.
3. Download pinned source archives for `kadm-platform-system` and `kadm-app-configs` into `cache/repos`; `kadm-platform-system` contains the Release Console under `console/`.
4. Render or inspect Kubernetes inputs and write `cache/images/runtime-images.txt`.
5. Pull all images in `runtime-images.txt`.
6. Export the images into `cache/images/runtime-images.tar.zst`.
7. Write SHA-256 checksums for files and image archive.
8. Fail the build if any image cannot be pulled, any expected archive is missing, or the final bundle is not internally consistent.

The builder should support authenticated GHCR pulls through environment variables:

```text
KADM_GHCR_USERNAME
KADM_GHCR_TOKEN
```

This is needed because the current demo app images may require authentication.

## Installer Flow

`install-kadm.sh prepare` changes from "download repos first, then bundle" to a bundle-first flow when `KADM_ASSET_BUNDLE_URL` is set or when using the default complete bundle:

1. Download or read `kadm-platform-assets.tgz`.
2. Run `kadmctl import-assets <bundle>`.
3. Restore workspace repositories from `cache/repos` when present.
4. Fall back to GitHub repository downloads only if the bundle is not marked complete.
5. Install local tools from `cache/tools` when present.

`kadmctl deploy --apply` changes as follows:

1. Install local K3s using the cached K3s binary and K3s airgap image bundle.
2. Verify K3s containerd is available.
3. Import `cache/images/runtime-images.tar.zst` into `k8s.io` by streaming it through `zstd -dc` into `sudo k3s ctr -n k8s.io images import -`.
4. Verify every image in `runtime-images.txt` exists in K3s containerd.
5. Install Gateway API, Cilium, Argo CD, and Argo Rollouts.

`kadmctl configure-delivery --apply` changes as follows:

1. Before applying the release-console overlay and app configs, verify release-console and app images in `runtime-images.txt` are present in K3s containerd.
2. If the imported complete bundle is missing, fail before applying resources that would create pods requiring registry pulls.

## Failure Policy

Complete offline mode fails closed.

If `KADM_OFFLINE_COMPLETE=true`, the installer must not silently download from public networks for assets covered by this design. It must fail with a clear missing-asset message for:

- missing repository archives,
- missing Helm archive,
- missing runtime image archive,
- invalid checksum,
- image import failure,
- missing image after import.

Partial mode remains available for older bundles, but the output must say that the bundle is not complete offline and that public network access may still be used.

## Size And Publishing

The current bundle is about 320 MB. Known added compressed image layers are about 660 MiB before the demo app images:

- Cilium runtime images: about 378 MiB.
- Argo CD, Argo Rollouts, and release-console: about 282 MiB.

The expected complete bundle size for the current project is about 1.1 GB to 1.5 GB. The design assumes GitHub Release assets, not Git-tracked files.

Publishing rules:

- Do not commit generated bundles to Git.
- Publish the bundle as a GitHub Release asset.
- Stop uploading the full bundle as a long-lived GitHub Actions artifact.
- If a single generated bundle reaches 1.8 GiB, split it into numbered parts before publishing.

The build should print the final size and warn when the bundle exceeds 1.5 GiB.

## Disk Requirements

The target installer machine needs space for:

- downloaded bundle,
- extracted cache,
- decompressed image archive during import,
- containerd image store.

The installer should require at least 8 GiB free and warn below 20 GiB free. The exact check should run before extracting or importing large image archives.

## Testing Strategy

Unit tests cover:

- importing a format-2 complete bundle,
- rejecting incomplete complete bundles,
- selecting cached Helm instead of downloading Helm,
- restoring workspace repositories from `cache/repos`,
- refusing network fallback when `KADM_OFFLINE_COMPLETE=true`,
- verifying image presence commands are emitted before platform install.

Integration-style shell tests cover:

- `install-kadm.sh prepare` with a fake complete bundle and fake repos,
- `kadmctl deploy --dry-run` output describing offline image import,
- `kadmctl deploy --apply` using fake `sudo k3s ctr` commands to verify import order,
- `kadmctl configure-delivery --apply` checking image presence before applying Kustomize.

Manual verification for the real bundle:

1. Build the complete offline bundle in CI or on a networked builder.
2. Transfer the bundle to a clean target host.
3. Block outbound traffic except SSH.
4. Run `install-kadm.sh all` with `KADM_ASSET_BUNDLE_URL=file:///.../kadm-platform-assets.tgz`.
5. Confirm Cilium, Argo CD, Argo Rollouts, release-console, and current demo app pods become ready without external registry pulls.

## Open Constraints

The first implementation supports `linux-amd64` only, matching the current K3s asset settings. Multi-architecture bundles should be separate named bundles to avoid growing the default package beyond GitHub Release asset limits.

Multi-node support is intentionally deferred. When workers are added later, the same runtime image archive must be imported on each node or replaced by a local registry design.
