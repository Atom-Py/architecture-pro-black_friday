#!/bin/bash

###
# Инициализация шардированного кластера MongoDB и наполнение бд.
# Запускать из директории mongo-sharding после docker compose up -d.
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

# Ждём, пока нода станет primary своего replica set
wait_primary() {
  local service=$1 port=$2
  until [ "$(docker compose exec -T "$service" mongosh --port "$port" --quiet --eval "db.hello().isWritablePrimary" 2>/dev/null)" = "true" ]; do
    echo "жду выбора primary на $service ..."
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

echo "2. Инициализируем replica set первого шарда"
wait_mongo shard1 27018
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
rs.initiate({
  _id: "shard1",
  members: [{ _id: 0, host: "shard1:27018" }]
})
EOF
wait_primary shard1 27018

echo "3. Инициализируем replica set второго шарда"
wait_mongo shard2 27018
docker compose exec -T shard2 mongosh --port 27018 --quiet <<EOF
rs.initiate({
  _id: "shard2",
  members: [{ _id: 0, host: "shard2:27018" }]
})
EOF
wait_primary shard2 27018

echo "4. Добавляем шарды в кластер через mongos и включаем шардирование коллекции"
wait_mongo mongos_router 27017
docker compose exec -T mongos_router mongosh --port 27017 --quiet <<EOF
sh.addShard("shard1/shard1:27018")
sh.addShard("shard2/shard2:27018")
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

echo "6. Документов на каждом шарде"
for shard in shard1 shard2; do
  docker compose exec -T "$shard" mongosh --port 27018 --quiet <<EOF
use somedb
print("$shard: " + db.helloDoc.countDocuments())
EOF
done

echo "Готово"
