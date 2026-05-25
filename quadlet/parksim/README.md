# Parksim Quadlet

Single quadlet for `hecate-parksim` — a multi-tenant parking simulator
collapsed from the former 7-service `hecate-parksim-*` family
(facility/lot/pricing/entry2exit/entry-island/exit-island/payment-terminal,
all retired 2026-05-25 in favour of a majestic monolith focused on feeding
`reckon-gateway` + `reckon-lazy` with credible traffic).

## Model

- **Tenant = container instance.** Multi-tenancy is operational, not
  architectural. To run N tenants, deploy N container instances with
  distinct `TENANT_ID` + `NODE_NAME` env values.
- **Each instance owns one reckon-db store** (`parksim_<TENANT_ID>_store`)
  and self-announces to `reckon_db_store_registry` via pg.
- **Erlang cluster** is optional. Multiple parksim containers (same
  cookie + dist seed) form one cluster; the registry mirrors all stores
  cluster-wide.

## Default topology

| Beam node    | IP            | Default container name | Default `TENANT_ID` |
|--------------|---------------|------------------------|---------------------|
| `beam00.lab` | 192.168.1.10  | `hecate-parksim`       | (deploy-time)       |
| `beam01.lab` | 192.168.1.11  | `hecate-parksim`       | (deploy-time)       |
| `beam02.lab` | 192.168.1.12  | `hecate-parksim`       | (deploy-time)       |
| `beam03.lab` | 192.168.1.13  | `hecate-parksim`       | (deploy-time)       |

This file targets a single instance per node. For multi-tenant beams,
duplicate `hecate-parksim.container` + `hecate-parksim.env` as
`hecate-parksim-<tenant>.container` / `.env` with distinct `TENANT_ID`
values.

## Files

```
quadlet/parksim/
├── hecate-parksim.container
└── hecate-parksim.env
```

## Deployment

Copy `hecate-parksim.container` + `hecate-parksim.env` onto the target
beam, then `systemctl --user daemon-reload && systemctl --user start
hecate-parksim`. Image auto-updates via `podman auto-update` /
`watchtower`.
