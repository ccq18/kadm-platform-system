# Deploy KADM Release Console

## 1. Build Image

The GitHub Actions workflow builds:

```text
ghcr.io/ccq18/kadm-release-console:<tag>
```

Manual trigger:

```bash
gh workflow run build-release-console.yaml --repo ccq18/kadm-platform-system -f image_tag=<tag>
```

## 2. Recommended Install Path

For normal clusters, use the platform installer:

```bash
export KADM_GITHUB_TOKEN=<github-token>

curl -fsSL https://raw.githubusercontent.com/ccq18/kadm-platform-system/main/bootstrap/install-kadm.sh | \
  bash -s -- all \
    --cluster kadm-test \
    --access-host root@<public-ip> \
    --private-ip <private-ip>
```

`kadmctl configure-delivery` creates Release Console secrets, Argo CD repository credentials, the app registry ConfigMap, and the Release Console deployment.

## 3. Manual Deployment

Manual deployment is mainly for development and recovery.

Create runtime secrets:

```bash
kubectl create namespace kadm --dry-run=client -o yaml | kubectl apply -f -

kubectl -n kadm create secret generic kadm-secrets \
  --from-literal=GITHUB_TOKEN=<github-token> \
  --from-literal=ARGOCD_BASE_URL=https://argocd-server.argocd.svc.cluster.local \
  --from-literal=ARGOCD_TOKEN=<argocd-token>
```

Create an image pull secret in the `kadm` namespace if the GHCR package is private:

```bash
kubectl -n kadm create secret docker-registry ghcr-cred \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<github-token>
```

Apply Release Console:

```bash
kubectl apply -k console/k8s/overlays/prod
```

Create app Applications from `kadm-app-configs`, not from application source repositories:

```bash
kubectl apply -k ../kadm-app-configs/apps/demo-hello/overlays/prod
kubectl apply -k ../kadm-app-configs/apps/demo-hello-spring/overlays/prod
```

## 4. Access

KADM Release Console is not exposed through Ingress by default. Use a tunnel:

```bash
kadmctl connect <cluster>
```

Or port-forward directly:

```bash
kubectl -n kadm port-forward svc/kadm 18080:80
```

Open:

```text
http://127.0.0.1:18080
```

Do not add a public Ingress until KADM Release Console has authentication, HTTPS, and an explicit access policy.
