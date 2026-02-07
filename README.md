# Hecate GitOps

GitOps configuration for Hecate node deployments using k3s and FluxCD.

## Overview

This repository is a **seed template** for Hecate deployments. During installation:

1. The installer clones this repo to `~/.hecate/gitops/`
2. You customize it (seal secrets, adjust configs)
3. You push to YOUR OWN remote (GitHub fork or private repo)
4. FluxCD watches your remote and auto-deploys changes

**Why a fork?** Flux requires a remote Git URL (http/https/ssh). Your fork becomes your cluster's source of truth, where you can add your own applications and sealed secrets.

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

## First-Time Setup: LLM API Keys

The Hecate daemon auto-detects commercial LLM providers from environment variables. To use Claude, GPT-4, or Gemini models, add your API keys during initial setup.

### Supported Providers

| Environment Variable | Provider | Models |
|---------------------|----------|--------|
| `ANTHROPIC_API_KEY` | Anthropic | Claude 3.5 Sonnet, Claude 3 Opus, etc. |
| `OPENAI_API_KEY` | OpenAI | GPT-4, GPT-4 Turbo, GPT-3.5, etc. |
| `GOOGLE_API_KEY` | Google | Gemini Pro, Gemini Ultra, etc. |

### Add API Keys (Install Time)

Run this from a machine with cluster access:

```bash
cd /path/to/hecate-gitops

# Option 1: Use the helper script (one key at a time)
./scripts/seal-secret.sh ANTHROPIC_API_KEY "sk-ant-api03-..."

# Copy the output and add to infrastructure/hecate/sealed-secrets.yaml:
# spec:
#   encryptedData:
#     ANTHROPIC_API_KEY: AgBy8h...  # paste encrypted value

# Option 2: Seal multiple keys at once
cat > /tmp/secrets.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: hecate-secrets
  namespace: hecate
stringData:
  ANTHROPIC_API_KEY: "sk-ant-..."
  OPENAI_API_KEY: "sk-..."
  GOOGLE_API_KEY: "..."
EOF

kubeseal --format yaml < /tmp/secrets.yaml > infrastructure/hecate/sealed-secrets.yaml
rm /tmp/secrets.yaml  # Don't commit plaintext!

# Commit and push
git add infrastructure/hecate/sealed-secrets.yaml
git commit -m "feat: add LLM provider API keys"
git push
```

### Add API Keys (After Install)

If the daemon is already running, you can add keys and hot-reload:

```bash
# 1. Seal and commit the new key (as above)
# 2. Wait for Flux to reconcile, or force it:
flux reconcile kustomization hecate-infrastructure

# 3. Restart the daemon to pick up new secrets:
kubectl rollout restart daemonset/hecate-daemon -n hecate

# Or call the reload endpoint (if secrets are already in the pod):
curl -X POST http://localhost:4444/api/llm/providers/reload
```

### Verify Providers

After setup, check that providers are detected:

```bash
curl http://localhost:4444/api/llm/providers | jq
# Should show: ollama, anthropic, openai, google (whichever keys you added)

curl http://localhost:4444/api/llm/models | jq '.models[].name'
# Should include models from all configured providers
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

## Well-Known Paths

Hecate uses standardized paths across all installations:

### Host Paths (on each node)

| Path | Purpose |
|------|---------|
| `/var/lib/hecate/` | Daemon persistent data (events, state) |
| `/run/hecate/` | Runtime files (Unix sockets) |
| `~/.hecate/` | User configuration directory |
| `~/.hecate/gitops/` | Local GitOps clone (for making changes) |
| `~/.hecate/kubeconfig` | Cluster access (optional) |

### Container Paths (inside daemon pod)

| Path | Mapped From |
|------|-------------|
| `/var/lib/hecate/` | Host `/var/lib/hecate/` |
| `/run/hecate/` | Host `/run/hecate/` |
| `/data/` | Legacy alias for `/var/lib/hecate/` |

### GitOps Workflow

```bash
# 1. Fork hecate-social/hecate-gitops on GitHub to YOUR_USERNAME/hecate-gitops

# 2. Clone YOUR fork locally
git clone git@github.com:YOUR_USERNAME/hecate-gitops.git ~/.hecate/gitops
cd ~/.hecate/gitops

# 3. Update flux-system/gotk-sync.yaml with your fork URL
sed -i 's|YOUR_USERNAME|your-actual-username|g' flux-system/gotk-sync.yaml

# 4. Seal your API keys
./scripts/seal-secret.sh ANTHROPIC_API_KEY "sk-ant-..."
# Add output to infrastructure/hecate/sealed-secrets.yaml

# 5. Commit and push to YOUR fork
git add -A && git commit -m "Initial setup with API keys"
git push origin main

# 6. Apply Flux configuration to cluster
kubectl apply -f flux-system/gotk-sync.yaml

# Flux now watches YOUR fork and auto-deploys changes
```

**For Hecate maintainers** (push access to hecate-social/hecate-gitops):
```bash
# Use upstream directly without forking
git clone git@github.com:hecate-social/hecate-gitops.git ~/.hecate/gitops
# Update gotk-sync.yaml to point to hecate-social/hecate-gitops
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
