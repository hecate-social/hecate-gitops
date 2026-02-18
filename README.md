# Hecate GitOps

Per-node GitOps configuration for Hecate deployments using **systemd + podman**.

## Overview

Each Hecate node has a local `~/.hecate/gitops/` directory containing Podman Quadlet
`.container` files. A lightweight reconciler watches this directory and symlinks
units into systemd, keeping the running state in sync with the declared state.

```
~/.hecate/gitops/                    ~/.config/containers/systemd/
├── system/                          (reconciler symlinks)
│   ├── hecate-daemon.container  ──> hecate-daemon.container -> gitops/...
│   └── hecate-daemon.env
└── apps/                            (installed on demand)
    ├── hecate-traderd.container ──> hecate-traderd.container -> gitops/...
    └── ...
```

**No cluster orchestrator.** Each node manages itself via systemd --user services.
Nodes discover each other via BEAM clustering (same cookie, host networking) and
the Macula mesh for WAN connectivity.

## Repository Structure

```
hecate-gitops/
├── quadlet/
│   ├── system/                     # Core daemon (always installed)
│   │   ├── hecate-daemon.container
│   │   └── hecate-daemon.env
│   ├── apps/                       # Plugins (installed on demand)
│   │   ├── hecate-traderd.container
│   │   ├── hecate-traderd.env
│   │   ├── hecate-traderw.container
│   │   ├── hecate-marthad.container
│   │   ├── hecate-marthad.env
│   │   └── hecate-marthaw.container
│   └── README.md
├── reconciler/
│   ├── hecate-reconciler.sh        # Watches gitops dir, reconciles symlinks
│   ├── hecate-reconciler.service   # systemd user service for reconciler
│   └── install-reconciler.sh       # Installer script
├── scripts/
│   ├── migrate-beam-to-podman.sh   # Migrate a node from k3s to podman
│   └── decommission-k3s.sh        # Remove k3s after migration
└── LICENSE
```

## How It Works

1. The installer seeds `~/.hecate/gitops/` with Quadlet files from this repo
2. The **reconciler** watches `~/.hecate/gitops/system/` and `~/.hecate/gitops/apps/`
3. It symlinks `.container` files to `~/.config/containers/systemd/`
4. `systemctl --user daemon-reload` picks up the Quadlet units
5. Podman runs containers as systemd user services

## Node Directory Layout

```
~/.hecate/
├── gitops/
│   ├── system/              # Core Quadlet files (from this repo)
│   └── apps/                # Plugin Quadlet files (installed via hecate CLI)
├── hecate-daemon/
│   ├── sqlite/              # SQLite read models
│   ├── reckon-db/            # Event store data (Khepri/Ra)
│   ├── sockets/             # Unix socket (api.sock)
│   ├── run/                 # Runtime files
│   └── connectors/          # External service connectors
├── config/
│   └── node.env             # Node-specific overrides (RAM, CPU, node name)
└── secrets/
    └── api-keys.env          # API keys (ANTHROPIC, GOOGLE, GROQ)
```

## Managing Services

```bash
# View all hecate services
systemctl --user list-units 'hecate-*'

# Check daemon status
systemctl --user status hecate-daemon

# Restart daemon
systemctl --user restart hecate-daemon

# View logs
journalctl --user -u hecate-daemon -f

# Install a plugin (copies Quadlet files to gitops/apps/)
hecate install trader

# Remove a plugin
hecate remove trader
```

## Secrets

API keys are stored in `~/.hecate/secrets/api-keys.env` (chmod 600) and
referenced from `~/.hecate/gitops/system/hecate-daemon.env`.

```bash
# Add or update API keys
cat >> ~/.hecate/gitops/system/hecate-daemon.env << 'EOF'
ANTHROPIC_API_KEY=sk-ant-...
GOOGLE_API_KEY=...
GROQ_API_KEY=...
EOF

# Restart daemon to pick up changes
systemctl --user restart hecate-daemon
```

## BEAM Clustering

Nodes in the same LAN cluster automatically via Erlang distribution:

- All nodes use `--network host` (no container networking)
- Cookie must match across nodes (`HECATE_COOKIE` in daemon env)
- Node names follow `hecate@hostname` convention
- Process groups (`pg`) handle intra-cluster communication

## Container Images

All images are published to `ghcr.io/hecate-social/`:

| Image | Description |
|-------|-------------|
| `ghcr.io/hecate-social/hecate-daemon` | Core daemon (Erlang/OTP) |
| `ghcr.io/hecate-social/hecate-traderd` | Trader daemon |
| `ghcr.io/hecate-social/hecate-traderw` | Trader frontend |
| `ghcr.io/hecate-social/hecate-marthad` | Martha AI daemon |
| `ghcr.io/hecate-social/hecate-marthaw` | Martha AI frontend |

Images are tagged with semver (e.g., `0.8.1`). Never use `:latest`.

## Podman 3.x Compatibility

Podman Quadlet requires 4.4+. On Ubuntu 20.04 (which ships podman 3.4.x via kubic),
the migration script generates plain `.service` files that call `podman run` directly,
achieving equivalent functionality without Quadlet support.
