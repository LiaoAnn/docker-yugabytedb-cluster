# YugabyteDB 3-node cluster (docker-compose)

This is a local, developer-friendly 3-node YugabyteDB cluster using `yugabyted` with Docker Compose v3.3.

References:
- https://docs.yugabyte.com/preview/quick-start/docker/

## Topology
- 3 nodes: `yb-node-1`, `yb-node-2`, `yb-node-3`
- Replication factor: defaults to 3 (you can explicitly set via `yugabyted configure`)
- Data persisted to named docker volumes
- Static container hostnames for stability
- Only node-1 maps ports to host for convenience
- yb-node-2/3 wait for `yb-node-1:15433` to be reachable before joining (to avoid race conditions)

Exposed ports (on host):
- 7000: YB-Master UI (node-1)
- 9000: YB-TServer UI (node-1)
- 15433: YugabyteDB UI (node-1)
- 5433: YSQL (PostgreSQL-compatible)
- 9042: YCQL

## Usage

Start the cluster:

```bash
cd infra/yugabytedb
docker compose up -d
```

Compose uses `depends_on` (basic order only) and an inline wait loop in yb-node-2/3 to ensure node-1 is ready. First boot may take tens of seconds.

Check container status:

```bash
docker ps --filter name=yb-node
```

Check cluster status (from node-1):

```bash
docker compose exec yb-node-1 bash -lc 'bin/yugabyted status --base_dir=/home/yugabyte/yb_data'
```

Optionally, explicitly set RF and placement policy (defaults are typically RF=3). From node-1 you can run:

```bash
docker compose exec yb-node-1 bash -lc 'bin/yugabyted configure data_placement --fault_tolerance=zone --rf=3'
```

Open UI:
- YSQL/YugabyteDB UI: http://localhost:15433
- Master UI: http://localhost:7000
- TServer UI: http://localhost:9000

Connect via ysqlsh:

```bash
docker compose exec yb-node-1 bash -lc "/home/yugabyte/bin/ysqlsh --echo-queries --host $(hostname)"
```

Connect from host (psql-compatible clients):
- Host: `localhost`
- Port: `5433`
- Database: `yugabyte`
- User: `yugabyte`
- Password: `yugabyte`

Scale or restart a node:

```bash
# Restart node-2
docker compose restart yb-node-2

# Recreate node-3 data (DANGEROUS: removes data volume)
docker compose down yb-node-3
docker volume rm yugabytedb_yb-node-3-data || true
```

Stop cluster (preserve data):

```bash
docker compose down
```

Stop cluster and remove data:

```bash
docker compose down -v
```

## Troubleshooting

- Node-2/3 failed with "Node at the join ip provided is not reachable":
  - This indicates node-1 was not ready yet. Compose now waits on port 15433; if your environment is slower, increase the wait loop (count or sleep) in `docker-compose.yml` for yb-node-2/3.
  - You can also rerun: `docker compose restart yb-node-2 yb-node-3`.

- Change exposed ports (e.g., macOS Monterey AirPlay conflict on 7000):
  - Edit `7000:7000` to `7001:7000` in `docker-compose.yml` for yb-node-1.

- Reset the cluster completely (DANGEROUS):
  ```bash
  docker compose down -v
  docker volume ls | awk '/yugabytedb/ {print $2}' | xargs -r docker volume rm
  ```

## Notes
- For macOS Monterey users, port 7000 may conflict with AirPlay. In that case, change the mapping to `7001:7000` in `docker-compose.yml`.
- The compose uses high `nofile` ulimits as recommended.
- Healthcheck waits for `yugabyted` to report `Running`.
- For multi-host or production, use proper deployment guides instead of Docker Compose.
  - Compose file version: 3.3. In v3, `depends_on` does not wait for health; we use an inline wait-on-port in node-2/3 command to avoid join races.
