# Hecate GitOps

GitOps configuration for Hecate node deployments using k3s and FluxCD.

## Overview

This repository is cloned during Hecate installation and serves as the local GitOps source for your cluster. FluxCD watches this repo and automatically applies changes.

## Structure

```
hecate-gitops/
├── infrastructure/
│   ├── sealed-secrets/     # Bitnami Sealed Secrets controller
│   └── hecate/
│       ├── namespace.yaml
│       ├── configmap.yaml      # Daemon configuration
│       ├── sealed-secrets.yaml # Encrypted secrets (API keys, etc.)
│       ├── headless-service.yaml
│       ├── daemonset.yaml
│       └── kustomization.yaml
├── apps/                   # Your applications go here
│   ├── README.md
│   └── kustomization.yaml
├── clusters/
│   └── local/              # Cluster-specific overrides
│       ├── kustomization.yaml
│       └── hardware-patch.yaml
├── flux-system/
│   └── gotk-sync.yaml      # FluxCD sync configuration
└── scripts/
    └── seal-secret.sh      # Helper for sealing secrets
```

## Architecture Decisions

| Concern | Decision | Rationale |
|---------|----------|-----------|
| **Daemon config** | ConfigMap + Kustomize patches | GitOps-native, per-cluster customization |
| **Secrets** | Sealed Secrets | Encrypted in git, only cluster can decrypt |
| **Ollama** | Systemd (outside k8s) | GPU passthrough, model persistence |
| **Multi-node** | Server-only gitops | FluxCD distributes to agents via k8s |

## Quick Start

After installation, your cluster is automatically synced with this repo.

### View current state
```bash
kubectl get pods -n hecate
kubectl get pods -n flux-system
```

### Make changes
```bash
cd ~/.hecate/gitops
# Edit manifests...
git add -A && git commit -m "Update config"
# FluxCD will apply within 1 minute
```

### Force sync
```bash
flux reconcile kustomization hecate-cluster
```

## Managing Secrets

Secrets are encrypted using Sealed Secrets. Only your cluster can decrypt them.

### Add an API key
```bash
# Create a temporary secret file (DO NOT COMMIT)
cat > /tmp/secret.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: hecate-secrets
  namespace: hecate
stringData:
  ANTHROPIC_API_KEY: "sk-ant-your-key-here"
  OPENAI_API_KEY: "sk-your-key-here"
EOF

# Seal it
kubeseal --format yaml < /tmp/secret.yaml > infrastructure/hecate/sealed-secrets.yaml

# Clean up and commit
rm /tmp/secret.yaml
git add -A && git commit -m "Add API keys"
```

Or use the helper script:
```bash
./scripts/seal-secret.sh --file /tmp/secret.yaml
```

### Install kubeseal CLI
```bash
# macOS
brew install kubeseal

# Linux
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.3/kubeseal-0.27.3-linux-amd64.tar.gz
tar -xzf kubeseal-*.tar.gz
sudo mv kubeseal /usr/local/bin/
```

## Deploying Applications

Add your applications to the `apps/` directory:

```bash
mkdir apps/my-service
cat > apps/my-service/deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-service
  template:
    metadata:
      labels:
        app: my-service
    spec:
      containers:
        - name: app
          image: my-image:latest
EOF

cat > apps/my-service/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
EOF

# Add to apps/kustomization.yaml
# resources:
#   - my-service/

git add -A && git commit -m "Add my-service"
```

## Cluster-Specific Configuration

Override settings for your specific cluster in `clusters/local/`:

### Increase daemon resources
```yaml
# clusters/local/daemon-resources.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: hecate-daemon
  namespace: hecate
spec:
  template:
    spec:
      containers:
        - name: daemon
          resources:
            limits:
              memory: 2Gi
              cpu: 2000m
```

Then add to `clusters/local/kustomization.yaml`:
```yaml
patches:
  - path: daemon-resources.yaml
```

## Multi-Node Clusters

For multi-node setups:

1. **Server node**: Has this gitops repo, runs FluxCD
2. **Agent nodes**: Join cluster, receive workloads via k8s

FluxCD only runs on the server. Agents don't need the gitops repo.

### Optional: Push to GitHub

For collaboration or backup, push to a remote:

```bash
git remote add origin git@github.com:youruser/my-hecate-gitops.git
git push -u origin main

# Update FluxCD to use remote
kubectl edit gitrepository hecate-gitops -n flux-system
# Change spec.url from file:// to https://github.com/...
```

## External Components

These run **outside** Kubernetes:

| Component | Manager | Location |
|-----------|---------|----------|
| **Ollama** | systemd | `/usr/local/bin/ollama` |
| **Models** | Ollama | `~/.ollama/models/` |
| **TUI** | User | `~/.local/bin/hecate-tui` |

## Troubleshooting

### Check FluxCD status
```bash
flux get all
flux logs
```

### Check daemon logs
```bash
kubectl logs -n hecate -l app=hecate-daemon -f
```

### Restart daemon
```bash
kubectl rollout restart daemonset/hecate-daemon -n hecate
```

### Sealed Secrets not decrypting
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=sealed-secrets
```
