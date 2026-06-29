# onecdctl Bootstrap And Connect Design

Date: 2026-06-26
Status: Approved for first implementation

## Goal

Provide a local installer flow that starts every self-hosted cluster from one empty server, configures local kubectl through an SSH tunnel, and lets the user open OneCD through a single command:

```bash
onecdctl connect
```

## Product Flow

Initial bootstrap runs from the user's local machine:

```bash
onecdctl bootstrap root@1.2.3.4 --name home-prod --private-ip 10.0.0.11 --apply
```

The bootstrap command installs the first K3s server in single-node embedded-etcd mode, retrieves kubeconfig, rewrites the kubeconfig endpoint to a local tunnel endpoint, and stores a local cluster profile under `~/.onecd/clusters/<cluster>/cluster.env`.

Daily access runs:

```bash
onecdctl connect home-prod
```

`connect` opens:

- SSH tunnel: `127.0.0.1:16443 -> first-master:6443`
- OneCD port-forward: `127.0.0.1:18080 -> svc/onecd:80`

The Kubernetes API is not exposed publicly by default. Only SSH must be reachable from the local machine.

## First Version Boundary

The first implementation focuses on the local installer contract:

- `bootstrap` defaults to dry-run and requires `--apply` for remote changes.
- `bootstrap --apply` installs the first K3s server and writes local kubectl/profile files.
- `connect` owns the safe access path through SSH tunnel plus kubectl port-forward.
- Later platform component installation can extend bootstrap after Cilium, Argo CD, Argo Rollouts, OneCD secrets, and GitOps bootstrap inputs are fully pinned.

## Node Expansion Model

All clusters begin with one master/server. Later nodes are added from OneCD Web:

- Worker: adds compute capacity.
- Master: joins the control plane. OneCD must warn that two masters are not highly available and three masters is the recommended HA shape.

## Local Files

```text
~/.onecd/clusters/<cluster>/cluster.env
~/.kube/onecd/<cluster>.yaml
```

The profile is a shell env file instead of JSON so the Bash CLI can load it without requiring `jq`.

## Safety

- No real secrets are committed to this repository.
- Remote-changing commands require `--apply`.
- `connect` runs in the foreground and stops SSH tunnel plus port-forward on `Ctrl-C`.
