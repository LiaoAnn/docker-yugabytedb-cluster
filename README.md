# Docker YugabyteDB Cluster

[中文說明 (Traditional Chinese)](./README.zh-TW.md)

A developer-friendly local 3-node YugabyteDB cluster using `yugabyted` and Docker Compose.

References:
- https://docs.yugabyte.com/preview/quick-start/docker/

## Topology & Ports
- Nodes: `yb-node-1`, `yb-node-2`, `yb-node-3`
- Replication factor: RF=3 by default (can be tuned with `yugabyted configure`)
- Data persisted to named Docker volumes
- Static container hostnames for stable joins
- Only node-1 exposes ports to the host
- node-2/3 wait for `yb-node-1:15433` before joining to avoid races

Host-exposed ports:
- 7000: YB-Master UI (node-1)
- 9000: YB-TServer UI (node-1)
- 15433: YugabyteDB/YSQL UI (node-1)
- 5433: YSQL (PostgreSQL-compatible)
- 9042: YCQL

## Quick start

Start the cluster (from repo root):

```bash
docker compose up -d
# If your environment still uses v1: docker-compose up -d
```

First boot can take a few tens of seconds.

List containers:

```bash
docker ps --filter name=yb-node
```

Check cluster status (inside node-1):

```bash
docker compose exec yb-node-1 bash -lc 'bin/yugabyted status --base_dir=/home/yugabyte/yb_data'
```

Open UIs:
- YSQL/YugabyteDB UI: http://localhost:15433
- Master UI: http://localhost:7000
- TServer UI: http://localhost:9000

## Create YSQL database and YCQL keyspace (recommended scripts)

```bash
# YSQL: create database (idempotent)
bash scripts/create-ysql-db.sh mydb

# YCQL: create keyspace (idempotent, default RF=3)
bash scripts/create-ycql-keyspace.sh mykeyspace 3
```

Or, using clients inside the container directly:

```bash
# YSQL create mydb (only if missing)
docker compose exec yb-node-1 bash -lc \
  "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname yugabyte --set ON_ERROR_STOP=1 --command \"DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'mydb') THEN EXECUTE 'CREATE DATABASE mydb'; END IF; END $$;\""

# YCQL create mykeyspace (RF=3)
docker compose exec yb-node-1 bash -lc \
  "/home/yugabyte/bin/ycqlsh \$(hostname) 9042 -e \"CREATE KEYSPACE IF NOT EXISTS mykeyspace WITH REPLICATION = { 'class': 'SimpleStrategy', 'replication_factor': 3 };\""
```

## Application connections (important)

Use the database name/keyspace name to connect. Do NOT use the Namespace Id (that is an internal cluster identifier).

Common connection parameters:
- Host: `localhost`
- YSQL: port `5433` (database name e.g., `mydb`)
- YCQL: port `9042` (keyspace e.g., `mykeyspace`)
- Default credentials (unless changed): user `yugabyte`, password `yugabyte`

### YSQL examples

Python (psycopg2)

```python
import psycopg2

conn = psycopg2.connect(
    host="localhost",
    port=5433,
    dbname="mydb",
    user="yugabyte",
    password="yugabyte"  # Remove if auth is not enforced
)
cur = conn.cursor()

cur.execute("CREATE TABLE IF NOT EXISTS todos (id SERIAL PRIMARY KEY, title TEXT)")
cur.execute("INSERT INTO todos (title) VALUES (%s) RETURNING id", ("hello from ysql",))
print("inserted id:", cur.fetchone()[0])
conn.commit()

cur.execute("SELECT id, title FROM todos ORDER BY id DESC LIMIT 5")
for row in cur:
    print(row)

cur.close()
conn.close()
```

Node.js (pg)

```javascript
// ysql.js
import { Client } from 'pg';

const client = new Client({
  host: 'localhost',
  port: 5433,
  database: 'mydb',
  user: 'yugabyte',
  password: 'yugabyte'   // Remove if auth is not enforced
});

await client.connect();

await client.query('CREATE TABLE IF NOT EXISTS todos (id SERIAL PRIMARY KEY, title TEXT)');
const res = await client.query('INSERT INTO todos (title) VALUES ($1) RETURNING id', ['hello from ysql']);
console.log('inserted id:', res.rows[0].id);

const { rows } = await client.query('SELECT id, title FROM todos ORDER BY id DESC LIMIT 5');
console.log(rows);

await client.end();
```

### YCQL examples

Python (cassandra-driver)

```python
from cassandra.cluster import Cluster
from cassandra.auth import PlainTextAuthProvider
from uuid import uuid4

auth = PlainTextAuthProvider("yugabyte", "yugabyte")  # Omit if auth is not enforced
cluster = Cluster(contact_points=["localhost"], port=9042, auth_provider=auth)
session = cluster.connect()

session.execute("""
CREATE KEYSPACE IF NOT EXISTS mykeyspace
WITH REPLICATION = { 'class': 'SimpleStrategy', 'replication_factor': 3 }
""")

session.set_keyspace("mykeyspace")
session.execute("CREATE TABLE IF NOT EXISTS todos (id uuid PRIMARY KEY, title text)")
session.execute("INSERT INTO todos (id, title) VALUES (%s, %s)", (uuid4(), "hello from ycql"))

rows = session.execute("SELECT id, title FROM todos LIMIT 5")
for r in rows:
    print(r.id, r.title)

cluster.shutdown()
```

Node.js (cassandra-driver)

```javascript
// ycql.js
import cassandra from 'cassandra-driver';

// Determine localDataCenter first via CLI below (system.local)
const client = new cassandra.Client({
  contactPoints: ['localhost'],
  localDataCenter: 'local', // Replace with your actual DC name
  protocolOptions: { port: 9042 },
  keyspace: 'mykeyspace',
  authProvider: new cassandra.auth.PlainTextAuthProvider('yugabyte', 'yugabyte') // Omit if auth is not enforced
});

await client.connect();

await client.execute(`
  CREATE TABLE IF NOT EXISTS todos (
    id uuid PRIMARY KEY,
    title text
  )
`);

const id = cassandra.types.Uuid.random();
await client.execute('INSERT INTO todos (id, title) VALUES (?, ?)', [id, 'hello from ycql'], { prepare: true });

const rs = await client.execute('SELECT id, title FROM todos LIMIT 5');
console.log(rs.rows);

await client.shutdown();
```

## Change or reset YSQL password

Reset the default superuser password (yugabyte):

```bash
docker compose exec yb-node-1 bash -lc \
  "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname yugabyte -c \"ALTER ROLE yugabyte WITH PASSWORD 'newpassword';\""
```

Create an application user and grant basic privileges (optional best practice):

```bash
# Create an app user (will error if it already exists; ignore the error or check first)
docker compose exec yb-node-1 bash -lc \
  "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname yugabyte -c \"CREATE ROLE app_user WITH LOGIN PASSWORD 'my_secret';\""

# Grant privileges on your app database (replace mydb if different)
docker compose exec yb-node-1 bash -lc \
  "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname mydb -c \"GRANT CONNECT ON DATABASE mydb TO app_user; GRANT USAGE ON SCHEMA public TO app_user; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user;\""
```

Notes:
- If authentication is not enforced, passwords may be ignored. To enforce auth, configure tserver flags such as `ysql_hba_conf_csv` and restart the cluster.
- For idempotent role creation, consider using a DO block to check existence before creating the role.

## CLI verification (no need to install psql)

The container already includes `ysqlsh`/`ycqlsh`, so you can test without installing clients on the host.

YSQL (inside container):

```bash
docker compose exec yb-node-1 bash -lc "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname mydb -c '\dt'"
```

YCQL (inside container):

```bash
# Determine data center (for YCQL driver localDataCenter)
docker compose exec yb-node-1 bash -lc "/home/yugabyte/bin/ycqlsh \$(hostname) 9042 -e \"SELECT data_center, rack FROM system.local;\""

# Describe keyspace
docker compose exec yb-node-1 bash -lc "/home/yugabyte/bin/ycqlsh \$(hostname) 9042 -e \"DESCRIBE KEYSPACE mykeyspace;\""
```

If you have psql installed on the host:

```bash
PGPASSWORD=yugabyte psql "host=localhost port=5433 dbname=mydb user=yugabyte" -c "\\dt"
```

## Operations

Restart/scale:

```bash
# Restart node-2
docker compose restart yb-node-2

# (Dangerous) Recreate node-3 data
docker compose down yb-node-3
docker volume rm yugabytedb_yb-node-3-data || true
```

Stop cluster (keep data):

```bash
docker compose down
```

Stop cluster and remove data:

```bash
docker compose down -v
```

## Troubleshooting

- node-2/3: "Node at the join ip provided is not reachable"
  - node-1 was not ready yet. The compose includes a wait-on-port for 15433. If your env is slower, increase the wait loop (count/sleep) for node-2/3 in `docker-compose.yml`.
  - You can also rerun: `docker compose restart yb-node-2 yb-node-3`.

- macOS Monterey port 7000 conflict (AirPlay)
  - Change the mapping to `7001:7000` for node-1.

- Enforce/adjust YSQL auth
  - You can reset password via `ALTER ROLE yugabyte WITH PASSWORD '...'`.
  - Or tune tserver flags (e.g., `ysql_hba_conf_csv`) to enforce auth; update compose and restart.

## Notes
- High `nofile` ulimit is configured as recommended.
- Healthcheck waits for `yugabyted` to report Running.
- For production/multi-host deployments, use official guides instead of Docker Compose.
- In Compose v3, `depends_on` does not wait for health; we use an inline wait in node-2/3 commands to avoid races.
