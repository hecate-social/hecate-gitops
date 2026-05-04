# Hecate Quadlet Units

Podman Quadlet `.container` files for managing Hecate services via systemd.

## Structure

```
quadlet/
└── system/                          # Core (always installed)
    ├── hecate-daemon.container      # Core daemon (Erlang/OTP)
    └── hecate-daemon.env            # Daemon environment config
```

Plugin Quadlets (e.g. trader, martha, snake-duel) are **not committed
here**. They are written at runtime by the hecate-daemon's plugin
lifecycle (`guide_plugin_lifecycle` app) into `~/.hecate/gitops/apps/`
when a license is granted via the appstore.

## How It Works

1. The installer (`hecate-install`) seeds `~/.hecate/gitops/system/` with the files in this directory
2. The reconciler symlinks `.container` files to `~/.config/containers/systemd/`
3. `systemctl --user daemon-reload` picks up the Quadlet units
4. Podman runs containers as systemd user services

For plugins, the daemon performs the same write-to-gitops step under
`~/.hecate/gitops/apps/`; the reconciler picks them up identically.

## Container Conventions

| Type | Network | Data | Health Check |
|------|---------|------|-------------|
| **Daemon** (`*d`) | `host` (BEAM clustering) | `~/.hecate/{name}/` bind mount | Socket file presence |
| **Frontend** (`*w`) | Published port | Stateless (no volume) | HTTP GET |

## Managing Services

```bash
# View all hecate services
systemctl --user list-units 'hecate-*'

# Daemon
systemctl --user status hecate-daemon
journalctl --user -u hecate-daemon -f

# Auto-update images
podman auto-update
```

## Environment Overrides

Node-specific overrides (hardware, clustering) go in `~/.hecate/config/node.env`.
The daemon `.container` file can be extended to load this via an additional `EnvironmentFile=`.
