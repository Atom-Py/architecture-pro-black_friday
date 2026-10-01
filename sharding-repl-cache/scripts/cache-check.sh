#!/bin/bash

###
# Проверка кеша: три запроса к /helloDoc/users подряд с замером времени.
# Первый запрос идёт в MongoDB, остальные должны отдаваться из redis.
###

set -e

url="http://localhost:8080/helloDoc/users"

for i in 1 2 3; do
  seconds=$(curl -s -o /dev/null -w "%{time_total}" "$url")
  ms=$(awk -v s="$seconds" 'BEGIN { printf "%d", s * 1000 }')
  echo "запрос $i: $ms мс"
done
