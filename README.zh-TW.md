# Docker YugabyteDB Cluster

一個開發者友善的本機 3 節點 YugabyteDB 叢集（使用 `yugabyted` 與 Docker Compose）。

參考文件：
- https://docs.yugabyte.com/preview/quick-start/docker/

## 拓撲與連線埠
- 節點：`yb-node-1`、`yb-node-2`、`yb-node-3`
- 預設複本數：RF=3（可用 `yugabyted configure` 調整）
- 資料持久化至命名 Docker volumes
- 固定容器主機名，方便穩定加入叢集
- 僅 node-1 對外映射連線埠
- node-2/3 在加入前會等待 `yb-node-1:15433` 就緒以避免競態

主機映射連線埠：
- 7000：YB-Master UI（node-1）
- 9000：YB-TServer UI（node-1）
- 15433：YugabyteDB/YSQL UI（node-1）
- 5433：YSQL（PostgreSQL 相容）
- 9042：YCQL

## 快速開始

在 repo 根目錄啟動叢集：

```bash
docker compose up -d
# 若你的環境仍使用 v1 指令：docker-compose up -d
```

首次啟動可能需要數十秒。

列出容器：

```bash
docker ps --filter name=yb-node
```

查看叢集狀態（於 node-1 內）：

```bash
docker compose exec yb-node-1 bash -lc 'bin/yugabyted status --base_dir=/home/yugabyte/yb_data'
```

開啟 UI：
- YSQL/YugabyteDB UI: http://localhost:15433
- Master UI: http://localhost:7000
- TServer UI: http://localhost:9000

## 建立 YSQL 資料庫與 YCQL keyspace（推薦使用腳本）

```bash
# YSQL：建立資料庫（冪等）
bash scripts/create-ysql-db.sh mydb

# YCQL：建立 keyspace（冪等，預設 RF=3）
bash scripts/create-ycql-keyspace.sh mykeyspace 3
```

或於容器內直接使用客戶端建立：

```bash
# YSQL 建立 mydb（若不存在才建立）
docker compose exec yb-node-1 bash -lc \
  "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname yugabyte --set ON_ERROR_STOP=1 --command \"DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'mydb') THEN EXECUTE 'CREATE DATABASE mydb'; END IF; END $$;\""

# YCQL 建立 mykeyspace（RF=3）
docker compose exec yb-node-1 bash -lc \
  "/home/yugabyte/bin/ycqlsh \$(hostname) 9042 -e \"CREATE KEYSPACE IF NOT EXISTS mykeyspace WITH REPLICATION = { 'class': 'SimpleStrategy', 'replication_factor': 3 };\""
```

## 應用程式連線（重要）

請使用「資料庫名稱 / keyspace 名稱」進行連線；不要使用 Namespace Id（它是叢集內部識別）。

通用連線參數：
- Host：`localhost`
- YSQL：port `5433`（資料庫名稱如 `mydb`）
- YCQL：port `9042`（keyspace 如 `mykeyspace`）
- 預設帳密（除非你更改過）：user `yugabyte`、password `yugabyte`

### YSQL 範例

Python（psycopg2）

```python
import psycopg2

conn = psycopg2.connect(
    host="localhost",
    port=5433,
    dbname="mydb",
    user="yugabyte",
    password="yugabyte"  # 若未強制啟用密碼，可移除
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

Node.js（pg）

```javascript
// ysql.js
import { Client } from 'pg';

const client = new Client({
  host: 'localhost',
  port: 5433,
  database: 'mydb',
  user: 'yugabyte',
  password: 'yugabyte'   // 若未強制啟用密碼，可移除
});

await client.connect();

await client.query('CREATE TABLE IF NOT EXISTS todos (id SERIAL PRIMARY KEY, title TEXT)');
const res = await client.query('INSERT INTO todos (title) VALUES ($1) RETURNING id', ['hello from ysql']);
console.log('inserted id:', res.rows[0].id);

const { rows } = await client.query('SELECT id, title FROM todos ORDER BY id DESC LIMIT 5');
console.log(rows);

await client.end();
```

### YCQL 範例

Python（cassandra-driver）

```python
from cassandra.cluster import Cluster
from cassandra.auth import PlainTextAuthProvider
from uuid import uuid4

auth = PlainTextAuthProvider("yugabyte", "yugabyte")  # 若未強制啟用密碼，可省略
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

Node.js（cassandra-driver）

```javascript
// ycql.js
import cassandra from 'cassandra-driver';

// 請先用下方 CLI 查詢 system.local 決定 localDataCenter
const client = new cassandra.Client({
  contactPoints: ['localhost'],
  localDataCenter: 'local', // 請改成實際的 DC 名稱
  protocolOptions: { port: 9042 },
  keyspace: 'mykeyspace',
  authProvider: new cassandra.auth.PlainTextAuthProvider('yugabyte', 'yugabyte') // 若未強制啟用密碼，可移除
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

## 修改或重設 YSQL 密碼

重設預設超級使用者（yugabyte）的密碼：

```bash
docker compose exec yb-node-1 bash -lc \
  "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname yugabyte -c \"ALTER ROLE yugabyte WITH PASSWORD 'newpassword';\""
```

建立應用程式使用者並授權（最佳實務，選擇性）：

```bash
# 建立 app 使用者（若已存在會報錯，可忽略或先檢查）
docker compose exec yb-node-1 bash -lc \
  "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname yugabyte -c \"CREATE ROLE appuser WITH LOGIN PASSWORD 'appsecret';\""

# 對你的應用程式資料庫授權（若資料庫不同，請更換 appdb）
docker compose exec yb-node-1 bash -lc \
  "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname appdb -c \"GRANT CONNECT ON DATABASE appdb TO appuser; GRANT USAGE ON SCHEMA public TO appuser; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO appuser;\""
```

注意：
- 若目前未強制啟用驗證，密碼可能不會被真正檢查。你可以透過 tserver 參數（如 `ysql_hba_conf_csv`）來強制驗證，並重啟叢集。
- 若想讓建立角色具備冪等性，可改用 DO 區塊先檢查存在性再建立。

## CLI 驗證（不需在主機安裝 psql）

容器已內建 `ysqlsh`/`ycqlsh`，即使主機沒有安裝 psql 也能測試。

YSQL（容器內）：

```bash
docker compose exec yb-node-1 bash -lc "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname appdb -c '\dt'"
```

YCQL（容器內）：

```bash
# 查詢 data center（供 YCQL 驅動設定 localDataCenter）
docker compose exec yb-node-1 bash -lc "/home/yugabyte/bin/ycqlsh \$(hostname) 9042 -e \"SELECT data_center, rack FROM system.local;\""

# 列出表
docker compose exec yb-node-1 bash -lc "/home/yugabyte/bin/ycqlsh \$(hostname) 9042 -e \"DESCRIBE KEYSPACE appks;\""
```

若主機已安裝 psql，也可以：

```bash
PGPASSWORD=yugabyte psql "host=localhost port=5433 dbname=appdb user=yugabyte" -c "\\dt"
```

## 管理操作

重新啟動/縮放：

```bash
# 重新啟動 node-2
docker compose restart yb-node-2

#（危險）重建 node-3 的資料
docker compose down yb-node-3
docker volume rm yugabytedb_yb-node-3-data || true
```

停止叢集（保留資料）：

```bash
docker compose down
```

停止叢集並刪除資料：

```bash
docker compose down -v
```

## 疑難排解

- node-2/3：出現「Node at the join ip provided is not reachable」
  - 表示 node-1 尚未就緒。compose 已包含等待 15433 的機制；若環境較慢可調整 `docker-compose.yml` 內 node-2/3 的等待次數或間隔。
  - 也可重試：`docker compose restart yb-node-2 yb-node-3`。

- macOS Monterey 與 7000 埠衝突（AirPlay）
  - 將對應改為 `7001:7000`。

- 強制啟用/調整 YSQL 驗證
  - 可透過 `ALTER ROLE yugabyte WITH PASSWORD '...'` 重設密碼。
  - 或調整 tserver flags（例如 `ysql_hba_conf_csv`）以強制驗證；更新 compose 後重啟。

## 備註
- 本 compose 已設定較高的 `nofile` ulimit。
- healthcheck 會等待 `yugabyted` 回報 Running。
- 生產或多主機部署請參考官方部署指南，不建議用 Docker Compose。
- Compose v3 的 `depends_on` 不會等待健康狀態，因此 node-2/3 的 command 內加入了等待以避免競態。
