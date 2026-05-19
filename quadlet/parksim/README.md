# Parksim Quadlets

Per-service quadlet units and env files for the `hecate-parksim-*` family.

## Topology

Four releases, one per beam node, single Erlang cluster (shared cookie
with the laptop reckon-gateway).

| Service                        | Beam node    | IP            | Erlang node name                          | Dist port |
|--------------------------------|--------------|---------------|-------------------------------------------|-----------|
| `hecate-parksim-entry2exit`    | `beam00.lab` | 192.168.1.10  | `parksim_entry2exit@192.168.1.10`         | 9100      |
| `hecate-parksim-lot`           | `beam01.lab` | 192.168.1.11  | `parksim_lot@192.168.1.11`                | 9100      |
| `hecate-parksim-pricing`       | `beam02.lab` | 192.168.1.12  | `parksim_pricing@192.168.1.12`            | 9100      |
| `hecate-parksim-simulator`     | `beam03.lab` | 192.168.1.13  | `parksim_simulator@192.168.1.13`          | 9100      |

The cookie is shared with the existing `reckon-gateway` instances (on
each beam and on the laptop), so any node that pings any other forms
one transitive cluster across all 9 BEAMs.

## Files

```
quadlet/parksim/
├── hecate-parksim-entry2exit.container   # beam00 target
├── hecate-parksim-entry2exit.env
├── hecate-parksim-lot.container          # beam01 target
├── hecate-parksim-lot.env
├── hecate-parksim-pricing.container      # beam02 target
├── hecate-parksim-pricing.env
├── hecate-parksim-simulator.container    # beam03 target
└── hecate-parksim-simulator.env
```

## Deployment

Stage-5 deploy script copies one `.container` + matching `.env` onto
its target beam, then `systemctl --user daemon-reload && systemctl --user
start <unit>`. The reconciler symlinks the container into
`~/.config/containers/systemd/`.

**Note:** the beam fleet currently runs `docker` + `watchtower` rather
than `podman` + `auto-update`. These quadlet files are forward-compatible
with the podman migration; the active mechanism is the equivalent
service entry in `compose/docker-compose.yml`.

## Seed-ping bootstrap

Erlang dist has no auto-discovery. Each parksim release reads
`HECATE_DIST_SEED` from its env file and connects to that node at boot
(planned in a subsequent commit; for now, ping manually after the unit
starts on the first beam).
