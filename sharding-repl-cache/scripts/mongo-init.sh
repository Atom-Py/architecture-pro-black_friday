#!/bin/bash

###
# Инициализация шардированного кластера MongoDB с репликацией и наполнение бд.
# Запускать из директории sharding-repl-cache после docker compose up -d.
###

set -e

cd "$(dirname "$0")/.."

# Ждём, пока нода начнёт отвечать на ping
wait_mongo() {
  local service=$1 port=$2
  until docker compose exec -T "$service" mongosh --port "$port" --quiet --eval "db.adminCommand('ping').ok" >/dev/null 2>&1; do
    echo "жду $service:$port ..."
    sleep 2
  done
}

# Ждём, пока в replica set появится primary
wait_primary() {
  local service=$1 port=$2
  until [ "$(docker compose exec -T "$service" mongosh --port "$port" --quiet --eval "rs.status().members.filter(m => m.stateStr == 'PRIMARY').length" 2>/dev/null)" = "1" ]; do
    echo "жду выбора primary в replica set на $service ..."
    sleep 2
  done
}

echo "1. Инициализируем replica set config server"
wait_mongo configSrv 27019
docker compose exec -T configSrv mongosh --port 27019 --quiet <<EOF
rs.initiate({
  _id: "config_server",
  configsvr: true,
  members: [{ _id: 0, host: "configSrv:27019" }]
})
EOF
wait_primary configSrv 27019

echo "2. Инициализируем replica set первого шарда из трёх нод"
wait_mongo shard1-1 27018
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
wait_primary shard1-1 27018

echo "3. Инициализируем replica set второго шарда из трёх нод"
wait_mongo shard2-1 27018
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
wait_primary shard2-1 27018

echo "4. Добавляем шарды в кластер через mongos и включаем шардирование коллекции"
wait_mongo mongos_router 27017
docker compose exec -T mongos_router mongosh --port 27017 --quiet <<EOF
sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018")
sh.addShard("shard2/shard2-1:27018,shard2-2:27018,shard2-3:27018")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { _id: "hashed" })
EOF

echo "5. Наполняем коллекцию somedb.helloDoc"
docker compose exec -T mongos_router mongosh --port 27017 --quiet <<EOF
use somedb
var docs = Array.from({ length: 1000 }, (_, i) => ({ age: i, name: "ly" + i }))
var result = db.helloDoc.insertMany(docs)
print("вставлено: " + Object.keys(result.insertedIds).length)
print("всего документов: " + db.helloDoc.countDocuments())
EOF

echo "6. Состояние replica set и количество документов на каждом шарде"
for shard in shard1 shard2; do
  docker compose exec -T "$shard-1" mongosh --port 27018 --quiet <<EOF
db.getMongo().setReadPref("primaryPreferred")
var members = rs.status().members
print("$shard: реплик " + members.length + ", " + members.map(m => m.name + " " + m.stateStr).join(", "))
use somedb
print("$shard: документов " + db.helloDoc.countDocuments())
EOF
done

echo "Готово"
