# Hecate GitOps

GitOps configuration for Hecate node deployments using k3s and FluxCD.

## Overview

This repository provides **upstream-managed GitOps** for Hecate deployments.

**How it works:**
1. Flux watches this upstream repo and auto-syncs all nodes
2. Updates to `hecate-social/hecate-gitops` propagate automatically to all clusters
3. Node-specific config (hardware, secrets) is applied locally by the installer
4. No fork needed for basic operation - just install and go

**For power users:** Fork this repo, set `HECATE_GITOPS_URL` during install, and customize freely.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Upstream: github.com/hecate-social/hecate-gitops                            │
│  • Base infrastructure (daemon, namespace, git-server)                       │
│  • Auto-syncs to all nodes (Flux pulls every 1m)                             │
└──────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  Local: ~/.hecate/gitops/                                                    │
│  ├── infrastructure/  ← from upstream (read-only)                            │
│  └── apps/            ← YOUR apps (edit, commit, push)                       │
│                                                                              │
│  Workflow: edit apps/ → git commit → git push local main → Flux deploys!    │
└──────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  git-server (in-cluster)                                                     │
│  • Serves local bare repo at http://git-server.hecate/ (via HTTP)            │
│  • Flux watches for user app changes (every 30s)                             │
│  • Push via: git push local main (uses bare repo on control-plane node)      │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Structure

```
hecate-gitops/
├── infrastructure/
│   ├── sealed-secrets/     # Bitnami Sealed Secrets controller
│   ├── git-server/         # Local git server for user apps
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   └── hecate/
│       ├── namespace.yaml
│       ├── configmap.yaml
│       ├── daemonset.yaml
│       └── ...
├── apps/                   # YOUR applications go here
│   ├── README.md
│   ├── kustomization.yaml
│   └── my-webapp/          # Example: add your apps here
│       └── deployment.yaml
├── clusters/
│   └── local/
│       ├── kustomization.yaml
│       └── hardware-patch.yaml
├── flux-system/
│   └── gotk-sync.yaml      # Flux watches upstream + local
└── scripts/
    └── seal-secret.sh
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

The Hecate daemon auto-detects commercial LLM providers from environment variables.

### Supported Providers

| Environment Variable | Provider | Models |
|---------------------|----------|--------|
| `ANTHROPIC_API_KEY` | Anthropic | Claude 3.5 Sonnet, Claude 3 Opus, etc. |
| `OPENAI_API_KEY` | OpenAI | GPT-4, GPT-4 Turbo, GPT-3.5, etc. |
| `GOOGLE_API_KEY` | Google | Gemini Pro, Gemini Ultra, etc. |

### Add API Keys (During Install)

Set environment variables before running the installer:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
export OPENAI_API_KEY="sk-..."
export GOOGLE_API_KEY="..."

# Run installer - it will detect and configure the keys
curl -fsSL https://hecate.social/install.sh | bash
```

The installer creates a Kubernetes secret (`hecate-secrets`) with your API keys.

### Add API Keys (After Install)

```bash
# Option 1: Re-run installer with keys set
export ANTHROPIC_API_KEY="sk-ant-..."
~/.hecate/install.sh  # or re-download

# Option 2: Create/update secret directly
kubectl create secret generic hecate-secrets -n hecate \
  --from-literal=ANTHROPIC_API_KEY="sk-ant-..." \
  --from-literal=OPENAI_API_KEY="sk-..." \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart daemon to pick up new secrets
kubectl rollout restart daemonset/hecate-daemon -n hecate

# Or hot-reload without restart
curl -X POST http://localhost:4444/api/llm/providers/reload
```

### Verify Providers

```bash
curl -s http://localhost:4444/api/llm/providers | jq 'keys'
# ["anthropic", "ollama", "openai"]

curl -s http://localhost:4444/api/llm/models | jq '.models[].name'
# claude-3-5-sonnet, gpt-4, llama3.2, etc.
```

## Managing Secrets

Secrets are applied locally by the installer (not stored in git). This keeps API keys out of version control.

### How Secrets Work

| Secret | Applied By | Stored In |
|--------|------------|-----------|
| `hecate-secrets` | Install script | Kubernetes only (not git) |
| `hecate-hardware` | Install script | Kubernetes only (not git) |

### Update Secrets

```bash
# View current secrets
kubectl get secret hecate-secrets -n hecate -o yaml

# Update a key
kubectl create secret generic hecate-secrets -n hecate \
  --from-literal=ANTHROPIC_API_KEY="new-key" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart daemon
kubectl rollout restart daemonset/hecate-daemon -n hecate
```

### Advanced: Sealed Secrets (for GitOps purists)

If you want secrets in git (encrypted), use Sealed Secrets:

```bash
# Install kubeseal
brew install kubeseal  # macOS
# or download from github.com/bitnami-labs/sealed-secrets

# Seal a secret
./scripts/seal-secret.sh ANTHROPIC_API_KEY "sk-ant-..."
# Add output to infrastructure/hecate/sealed-secrets.yaml
```

## Deploying Your Apps

Apps are deployed via the local git server. Flux watches and auto-deploys.

### Quick Start

```bash
cd ~/.hecate/gitops/apps

# Create your app
mkdir my-webapp
cat > my-webapp/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-webapp
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-webapp
  template:
    metadata:
      labels:
        app: my-webapp
    spec:
      containers:
        - name: app
          image: nginx:alpine
          ports:
            - containerPort: 80
EOF

cat > my-webapp/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
EOF

# Add to apps kustomization
echo "  - my-webapp" >> kustomization.yaml

# Commit and push to local git server
git add -A
git commit -m "Add my-webapp"
git push local main

# Flux deploys within 30 seconds!
kubectl get pods -l app=my-webapp
```

### How It Works

1. **Edit** files in `~/.hecate/gitops/apps/`
2. **Commit** your changes: `git commit -am "Update my-webapp"`
3. **Push** to local: `git push local main`
4. **Flux** detects changes and applies them (every 30s)

### Legacy Method

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
