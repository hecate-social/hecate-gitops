# Hecate Quadlet Units

Podman Quadlet `.container` files for managing Hecate services via systemd.

## Structure

```
quadlet/
├── system/                          # Core (always installed)
│   ├── hecate-daemon.container      # Core daemon (Erlang/OTP)
│   └── hecate-daemon.env            # Daemon environment config
└── apps/                            # Plugins (installed on demand)
    ├── hecate-traderd.container      # Trader daemon
    ├── hecate-traderd.env            # Trader daemon config
    ├── hecate-traderw.container      # Trader web frontend
    ├── hecate-marthad.container      # Martha AI daemon
    ├── hecate-marthad.env            # Martha daemon config
    └── hecate-marthaw.container      # Martha web frontend
```

## How It Works

1. The installer (`hecate-node`) seeds `~/.hecate/gitops/` with these files
2. The reconciler symlinks `.container` files to `~/.config/containers/systemd/`
3. `systemctl --user daemon-reload` picks up the Quadlet units
4. Podman runs containers as systemd user services

## Service Dependencies

```
hecate-daemon.service
├── hecate-traderd.service (Requires=hecate-daemon)
│   └── hecate-traderw.service (After=hecate-traderd)
└── hecate-marthad.service (Requires=hecate-daemon)
    └── hecate-marthaw.service (After=hecate-marthad)
```

## Container Types

| Type | Network | Data | Health Check |
|------|---------|------|-------------|
| **Daemon** (`*d`) | `host` (BEAM clustering) | `~/.hecate/{name}/` bind mount | Socket file presence |
| **Frontend** (`*w`) | Published port | Stateless (no volume) | HTTP GET |

## Managing Services

```bash
# View all hecate services
systemctl --user list-units 'hecate-*'

# Start/stop a plugin
systemctl --user start hecate-traderd
systemctl --user stop hecate-traderd

# View logs
journalctl --user -u hecate-daemon -f
journalctl --user -u hecate-traderd -f

# Auto-update images
podman auto-update --authfile ~/.hecate/secrets/ghcr-auth.json
```

## Environment Overrides

Node-specific overrides (hardware, clustering) go in `~/.hecate/config/node.env`.
The daemon `.container` file can be extended to load this via an additional `EnvironmentFile=`.

## Port Allocation

| Service | Port | Protocol |
|---------|------|----------|
| hecate-daemon | Unix socket only | - |
| hecate-traderd | Unix socket only | - |
| hecate-traderw | 5174 | HTTP |
| hecate-marthaw | 5175 | HTTP |
