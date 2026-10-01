# pymongo-api: шардирование MongoDB

Стенд из приложения и шардированного кластера MongoDB:

| Сервис | Роль | Порт |
| :- | :- | :- |
| `configSrv` | config server, replica set `config_server` | 27019 |
| `shard1` | первый шард, replica set `shard1` | 27018 |
| `shard2` | второй шард, replica set `shard2` | 27018 |
| `mongos_router` | маршрутизатор mongos, точка входа для приложения | 27017 |
| `pymongo_api` | приложение, образ `kazhem/pymongo_api:1.0.0` | 8080 |

Приложение подключается только к `mongos_router`, о шардах оно ничего не знает.

## Как запустить

Поднимаем контейнеры

```shell
docker compose up -d
```

Инициализируем кластер и наполняем бд одним скриптом

```shell
./scripts/mongo-init.sh
```

Скрипт выполняет шаги, описанные ниже, и в конце печатает количество документов
в коллекции целиком и на каждом шарде.

## Шаги инициализации

Те же команды, что в скрипте, если нужно выполнить их вручную.

1. Инициализируем replica set config server

```shell
docker compose exec -T configSrv mongosh --port 27019 --quiet <<EOF
rs.initiate({
  _id: "config_server",
  configsvr: true,
  members: [{ _id: 0, host: "configSrv:27019" }]
})
EOF
```

2. Инициализируем replica set каждого шарда. Пока в каждом по одной ноде

```shell
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
rs.initiate({
  _id: "shard1",
  members: [{ _id: 0, host: "shard1:27018" }]
})
EOF

docker compose exec -T shard2 mongosh --port 27018 --quiet <<EOF
rs.initiate({
  _id: "shard2",
  members: [{ _id: 0, host: "shard2:27018" }]
})
EOF
```

3. Через mongos добавляем шарды в кластер, включаем шардирование для бд `somedb`
и коллекции `helloDoc`. Ключ шардирования: хеш от `_id`, так документы ложатся
на шарды примерно поровну

```shell
docker compose exec -T mongos_router mongosh --port 27017 --quiet <<EOF
sh.addShard("shard1/shard1:27018")
sh.addShard("shard2/shard2:27018")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { _id: "hashed" })
EOF
```

4. Наполняем коллекцию тестовыми данными

```shell
docker compose exec -T mongos_router mongosh --port 27017 --quiet <<EOF
use somedb
var docs = Array.from({ length: 1000 }, (_, i) => ({ age: i, name: "ly" + i }))
var result = db.helloDoc.insertMany(docs)
db.helloDoc.countDocuments()
EOF
```

## Как проверить

Общее количество документов через mongos

```shell
docker compose exec -T mongos_router mongosh --port 27017 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

Количество документов на каждом шарде

```shell
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

docker compose exec -T shard2 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

Распределение чанков по шардам

```shell
docker compose exec -T mongos_router mongosh --port 27017 --quiet <<EOF
sh.status()
EOF
```

Приложение: http://localhost:8080. В ответе `mongo_topology_type` равен `Sharded`,
в `shards` перечислены оба шарда, в `collections.helloDoc.documents_count` 1000 документов.
Список эндпоинтов: http://localhost:8080/docs.

## Как остановить

```shell
docker compose down -v
```
