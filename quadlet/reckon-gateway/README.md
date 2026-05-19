# reckon-gateway (catalogue mode) — per-beam deploys

`reckon-gateway` 0.5.0 is a multi-cluster catalogue gateway: pure
gRPC ingress, no data plane. Deploy ONE instance per beam node so
lazyreckon clients can connect to any beam in the lab and see the
same view.

## Topology

| Beam node    | gRPC port | Erlang node name                  |
|--------------|-----------|-----------------------------------|
| beam00.lab   | 50051     | `reckon_gateway@192.168.1.10`     |
| beam01.lab   | 50051     | `reckon_gateway@192.168.1.11`     |
| beam02.lab   | 50051     | `reckon_gateway@192.168.1.12`     |
| beam03.lab   | 50051     | `reckon_gateway@192.168.1.13`     |

Each instance connects to every cluster listed in its
`clusters.eterm` (currently only the parksim cluster). The four
gateways are independent: each holds its own catalogue cache,
maintains its own dist connections to parksim. Lazyreckon picks any
one by endpoint; failover is "change the endpoint".

## Files

```
quadlet/reckon-gateway/
├── README.md
├── reckon-gateway.container         # quadlet (podman / forward-compat)
├── reckon-gateway-beam00.env        # per-beam: NODE_NAME pinned to beam IP
├── reckon-gateway-beam01.env
├── reckon-gateway-beam02.env
└── reckon-gateway-beam03.env
```

## Cookies live OUTSIDE this repo

`clusters.eterm` is **not** in gitops. It carries cookies (Erlang
dist auth credentials = equivalent to passwords). It lives on each
beam at:

```
/home/rl/.hecate/secrets/reckon-gateway-clusters.eterm   (chmod 0600)
```

The reckon-gateway container bind-mounts that path read-only at
`/etc/reckon-gateway/clusters.eterm`.

Format:

```erlang
[
    #{cluster_id => parksim,
      members    => ['parksim_entry2exit@192.168.1.10',
                     'parksim_lot@192.168.1.11',
                     'parksim_pricing@192.168.1.12',
                     'parksim_simulator@192.168.1.13'],
      cookie     => <<"tKcK...">>,
      api_module => esdb_gater_api}    %% parksim runs reckon_gater 1.3.1
].
```

`api_module` defaults to `reckon_gater_api`; parksim's older
reckon_gater 1.3.1 exposes `esdb_gater_api` instead.

## Deployment

Stage 5 (forthcoming): build the new image via CI, distribute the
clusters.eterm to each beam (operator step, out-of-band of gitops),
roll out the quadlet to each beam via the canonical
`macula-demo/infrastructure/beamXX.lab/docker-compose.yml`
mechanism.
