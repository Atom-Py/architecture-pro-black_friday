# pymongo-api: шардирование, репликация и кеширование

Итоговый стенд: приложение, redis для кеша и шардированный кластер MongoDB,
в котором каждый шард это replica set из трёх нод:

| Сервис | Роль | Порт |
| :- | :- | :- |
| `configSrv` | config server, replica set `config_server` | 27019 |
| `shard1-1`, `shard1-2`, `shard1-3` | ноды первого шарда, replica set `shard1` | 27018 |
| `shard2-1`, `shard2-2`, `shard2-3` | ноды второго шарда, replica set `shard2` | 27018 |
| `mongos_router` | маршрутизатор mongos, точка входа для приложения | 27017 |
| `redis` | кеш ответов приложения | 6379 |
| `pymongo_api` | приложение, образ `kazhem/pymongo_api:1.0.0` | 8080 |

Приложение подключается к `mongos_router` и к `redis`. Адрес redis передаётся
переменной окружения `REDIS_URL=redis://redis:6379`, при её наличии приложение
кеширует ответы эндпоинта `/{collection_name}/users` на 60 секунд.

## Как запустить

Поднимаем контейнеры

```shell
docker compose up -d
```

Инициализируем кластер и наполняем бд одним скриптом

```shell
./scripts/mongo-init.sh
```

Скрипт выполняет шаги, описанные ниже, и в конце печатает состав каждого replica set
и количество документов в коллекции целиком и на каждом шарде.

## Шаги инициализации

Те же команды, что в скрипте, если нужно выполнить их вручную. Между шагами нужно
дождаться, пока в replica set выберется primary, обычно это несколько секунд.

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

2. Инициализируем replica set первого шарда. Команда выполняется на одной ноде,
остальные две она добавляет в набор сама

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.initiate({
  _id: "shard1",
  members: [
    { _id: 0, host: "shard1-1:27018" },
    { _id: 1, host: "shard1-2:27018" },
    { _id: 2, host: "shard1-3:27018" }
  ]
})
EOF
```

3. То же для второго шарда

```shell
docker compose exec -T shard2-1 mongosh --port 27018 --quiet <<EOF
rs.initiate({
  _id: "shard2",
  members: [
    { _id: 0, host: "shard2-1:27018" },
    { _id: 1, host: "shard2-2:27018" },
    { _id: 2, host: "shard2-3:27018" }
  ]
})
EOF
```

4. Через mongos добавляем шарды в кластер. Шард указывается как replica set
со списком всех его нод, так mongos сам найдёт primary после переизбрания.
Затем включаем шардирование для бд `somedb` и коллекции `helloDoc` по хешу `_id`

```shell
docker compose exec -T mongos_router mongosh --port 27017 --quiet <<EOF
sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018")
sh.addShard("shard2/shard2-1:27018,shard2-2:27018,shard2-3:27018")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { _id: "hashed" })
EOF
```

5. Наполняем коллекцию тестовыми данными

```shell
docker compose exec -T mongos_router mongosh --port 27017 --quiet <<EOF
use somedb
var docs = Array.from({ length: 1000 }, (_, i) => ({ age: i, name: "ly" + i }))
var result = db.helloDoc.insertMany(docs)
db.helloDoc.countDocuments()
EOF
```

Redis отдельной настройки не требует, приложение начинает писать в него при первом
запросе к кешируемому эндпоинту.

## Как проверить

Приложение: http://localhost:8080. В ответе `mongo_topology_type` равен `Sharded`,
в `shards` для каждого шарда перечислены три его ноды,
в `collections.helloDoc.documents_count` 1000 документов, `cache_enabled` равен `true`.
Список эндпоинтов: http://localhost:8080/docs.

Скорость кеша: три запроса к `/helloDoc/users` подряд с замером времени

```shell
./scripts/cache-check.sh
```

Первый запрос идёт в MongoDB и занимает больше секунды, второй и третий отдаются
из redis и укладываются в 100 мс. Тот же замер вручную:

```shell
curl -s -o /dev/null -w "%{time_total}\n" http://localhost:8080/helloDoc/users
curl -s -o /dev/null -w "%{time_total}\n" http://localhost:8080/helloDoc/users
```

Ключи кеша в redis

```shell
docker compose exec -T redis redis-cli keys "api:cache*"
```

Состав replica set шарда и роли нод

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.status().members.map(m => m.name + " " + m.stateStr)
EOF
```

Общее количество документов через mongos

```shell
docker compose exec -T mongos_router mongosh --port 27017 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

Количество документов на каждом шарде. Нода, к которой подключаемся, может оказаться
secondary, поэтому сначала разрешаем чтение не только с primary

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
db.getMongo().setReadPref("primaryPreferred")
use somedb
db.helloDoc.countDocuments()
EOF

docker compose exec -T shard2-1 mongosh --port 27018 --quiet <<EOF
db.getMongo().setReadPref("primaryPreferred")
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

## Как остановить

```shell
docker compose down -v
```
