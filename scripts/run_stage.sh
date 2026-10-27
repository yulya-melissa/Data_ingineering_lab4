#!/usr/bin/env bash
# Этапы 3 и 4: результат сохраняется в logs/stageN/run.txt

set -o pipefail

STAGE="${1:-}"

case "$STAGE" in
  3) FENCING=0 ;;
  4) FENCING=1 ;;
  *)
    echo "Использование: $0 3|4"
    exit 1
    ;;
esac

PAUSE_SECONDS="${PAUSE_SECONDS:-40}"
PAUSE_AT_CHUNK="${PAUSE_AT_CHUNK:-10}"

if ! [[ "$PAUSE_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "ОШИБКА: PAUSE_SECONDS должен быть неотрицательным числом"
  exit 1
fi

if ! [[ "$PAUSE_AT_CHUNK" =~ ^[0-9]+$ ]] ||
   (( PAUSE_AT_CHUNK < 1 || PAUSE_AT_CHUNK > 30 )); then
  echo "ОШИБКА: PAUSE_AT_CHUNK должен быть от 1 до 30"
  exit 1
fi

cd "$(dirname "$0")/.." || exit 1

export RUN_ID="stage$STAGE"
export FENCING
export HOST_UID="${HOST_UID:-0}"
export HOST_GID="${HOST_GID:-0}"

OUT="logs/$RUN_ID"

mkdir -p "$OUT"

exec > >(tee -a "$OUT/run.txt") 2>&1

# ---------- вспомогательные функции ----------

say() {
  printf '\n[%s] %s\n' "$(date +%T)" "$*"
}

die() {
  printf '\nОШИБКА: %s\n' "$*" >&2
  exit 1
}

run() {
  printf '    $'
  printf ' %q' "$@"
  printf '\n'

  local rc
  local -a filters=(
    grep -v -E \
      'Emulate Docker CLI|Executing external compose provider'
  )

  "$@" 2>&1 |
    "${filters[@]}" |
    sed 's/^/      /'

  rc=${PIPESTATUS[0]}

  if (( rc != 0 )); then
    printf '      Команда завершилась с кодом %s\n' "$rc" >&2
    return "$rc"
  fi

  return 0
}

service_exists() {
  docker compose config --services 2>/dev/null |
    grep -Fxq -- "$1"
}

# FIX: ищем контейнеры и по compose ps, и по label — ловит "improper"/paused.
cleanup_containers() {
  local service id rc=0 ids

  for service in coord1 coord2 sink; do
    ids=$(docker compose ps -aq "$service" 2>/dev/null)
    ids="$ids $(docker ps -aq \
      --filter "label=com.docker.compose.service=$service" 2>/dev/null)"
    ids=$(printf '%s\n' $ids | sort -u)

    for id in $ids; do
      [[ -z "$id" ]] && continue
      echo "      Очистка $service ($id)"
      docker unpause "$id" >/dev/null 2>&1 || true
      docker stop -t 1 "$id" >/dev/null 2>&1 || true
      if ! docker rm -f "$id" >/dev/null 2>&1; then
        echo "      Не удалось удалить $service ($id)" >&2
        rc=1
      fi
    done
  done

  return "$rc"
}

wait_for() {
  local file="$1"
  local pattern="$2"
  local limit="$3"
  local label="$4"
  local end line

  end=$(( $(date +%s) + limit ))

  while (( $(date +%s) < end )); do
    if [[ -f "$file" ]]; then
      line=$(grep -m1 -E -- "$pattern" "$file" 2>/dev/null || true)
      if [[ -n "$line" ]]; then
        printf '%s' "$line"
        return 0
      fi
    fi
    sleep 0.3
  done

  die "не дождались: $label (файл $file, шаблон '$pattern')"
}

epoch_of_line() {
  local timestamp
  timestamp=$(grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z' \
    <<< "$1" | head -n 1)
  [[ -n "$timestamp" ]] ||
    die "не удалось извлечь UTC-время из строки: $1"
  date -u -d "$timestamp" +%s.%N
}

diff_s() {
  awk -v a="$1" -v b="$2" \
    'BEGIN { printf "%.1f", a-b }'
}

zk_exec() {
  docker compose exec -T zoo1 zkCli.sh \
    -server zoo1:2181 "$@"
}

# ---------- подготовка ----------

echo "============================================================"
echo " Этап $STAGE: приостановка лидера, FENCING=$FENCING"

if [[ "$FENCING" == 1 ]]; then
  echo " Защита по эпохе ВКЛЮЧЕНА"
  echo " Получатель должен отклонить запись старого лидера"
else
  echo " Защита по эпохе ВЫКЛЮЧЕНА"
  echo " Получатель может принять запись старого лидера"
fi

echo " Запуск: $(date)"
echo "============================================================"

for service in zoo1 zoo2 zoo3 coord1 coord2 sink; do
  service_exists "$service" ||
    die "сервис '$service' отсутствует в конфигурации Compose"
done

say "1. Очищаю контейнеры и состояние предыдущего запуска"

cleanup_containers ||
  die "не удалось удалить старые контейнеры"

rm -rf -- state
mkdir -p state "$OUT"

# FIX: чистим логи прошлых запусков, чтобы шаг 13 не показывал старые ACCEPTED.
rm -f "$OUT"/coord1.log "$OUT"/coord2.log "$OUT"/sink.log

say "2. Запускаю и проверяю три сервера ZooKeeper"

run docker compose up -d zoo1 zoo2 zoo3 ||
  die "не удалось запустить ZooKeeper"

ZK_READY=0
for _ in $(seq 1 30); do
  if docker compose exec -T zoo1 zkServer.sh status 2>&1 |
      grep -q 'Mode:'; then
    ZK_READY=1
    break
  fi
  sleep 2
done

(( ZK_READY == 1 )) || die "ZooKeeper не отвечает"

echo "      ZooKeeper работает"

say "3. Сбрасываю состояние выборов лидера в ZooKeeper"

if ! zk_exec deleteall "/failover/$RUN_ID" >/dev/null 2>&1; then
  echo "      Узел отсутствует или deleteall не выполнен."
  echo "      Проверяю, что запуск координаторов возможен."
fi

say "4. Запускаю sink и первого координатора coord1"

run docker compose up -d --build --force-recreate sink coord1 ||
  die "не удалось запустить sink и coord1"

L=$(wait_for "$OUT/coord1.log" \
  'BECAME_LEADER' 90 "coord1 стал лидером")

echo "      ${L#*] } <- coord1 стал лидером"

say "5. Запускаю резервного координатора coord2"

# FIX: явно убираем возможный залипший coord2 перед force-recreate.
run docker compose rm -sf coord2 >/dev/null 2>&1 || true

run docker compose up -d --force-recreate coord2 ||
  die "не удалось запустить coord2"

wait_for "$OUT/coord2.log" \
  'STANDBY' 60 "coord2 перешёл в STANDBY" >/dev/null

echo "      coord2 ожидает своей очереди (STANDBY)"

say "6. Жду chunk $PAUSE_AT_CHUNK из 30"

wait_for "$OUT/coord1.log" \
  "chunk $PAUSE_AT_CHUNK/" 90 "прогресс coord1" >/dev/null

say "7. Замораживаю coord1"

T_PAUSE=$(date -u +%s.%N)

run docker compose pause coord1 ||
  die "не удалось приостановить coord1"

# FIX: восстановлена строка, которая была побита ("AUSE +%T.%3N").
echo "      Время заморозки: $(date -u -d "@$T_PAUSE" +%T.%3N) UTC"

printf '%s\n' "$(date -u -d "@$T_PAUSE" +%T.%3N)" \
  > "$OUT/pause_time.txt"

say "8. Жду перехода лидерства к coord2"

L=$(wait_for "$OUT/coord2.log" \
  'BECAME_LEADER' 90 "coord2 стал лидером")

T_LEADER=$(epoch_of_line "$L")
SWITCH=$(diff_s "$T_LEADER" "$T_PAUSE")

echo "      ${L#*] }"

L=$(wait_for "$OUT/coord2.log" \
  'RESUME|чекпоинта нет' 30 "возобновление coord2")

echo "      ${L#*] }"
echo "      >>> ЛИДЕР СМЕНИЛСЯ ЧЕРЕЗ $SWITCH с ПОСЛЕ ЗАМОРОЗКИ <<<"

echo "Лидер сменился через $SWITCH с после заморозки (таймаут сессии 10 с)" \
  > "$OUT/leader_change.txt"

say "9. Жду публикации результата coord2"

L=$(wait_for "$OUT/coord2.log" \
  'PUBLISHED|PUBLISH_REJECTED' 120 "публикация coord2")

echo "      ${L#*] }"

say "10. Жду окончания паузы $PAUSE_SECONDS с"

LEFT=$(awk \
  -v t="$T_PAUSE" \
  -v n="$(date -u +%s.%N)" \
  -v p="$PAUSE_SECONDS" \
  'BEGIN { d=p-(n-t); printf "%.3f", (d>0 ? d : 0) }')

echo "      Осталось ждать: $LEFT с"
sleep "$LEFT"

say "11. Размораживаю старый coord1"

CID="zk-failover-coord1-1"
docker unpause "$CID" || die "не удалось разморозить coord1"

STATUS=$(docker inspect "$CID" --format '{{.State.Status}}' 2>/dev/null)
[[ "$STATUS" == "running" ]] || die "coord1 остался в состоянии '$STATUS' после unpause"
echo "      coord1 разморожен, статус: $STATUS"

echo "      Пауза длилась $(diff_s "$(date -u +%s.%N)" "$T_PAUSE") с"

say "12. Жду попытки публикации coord1"

L=$(wait_for "$OUT/coord1.log" \
  'PUBLISHED|PUBLISH_REJECTED' 150 "публикация coord1")

echo "      ${L#*] }"

sleep 1

say "13. Результаты приёмника sink"

if [[ -f "$OUT/sink.log" ]]; then
  grep -E 'ACCEPTED|REJECTED' "$OUT/sink.log" |
    sed 's/^/      /' || true
else
  echo "      Предупреждение: $OUT/sink.log отсутствует"
fi

say "14. Проверяю результат через scripts/verify.py"

if [[ ! -f scripts/verify.py ]]; then
  die "файл scripts/verify.py не найден"
fi

if python3 scripts/verify.py > "$OUT/verify.txt" 2>&1; then
  sed 's/^/      /' "$OUT/verify.txt"
else
  sed 's/^/      /' "$OUT/verify.txt"
  echo "      Предупреждение: проверка результата завершилась с ошибкой"
fi

if [[ -d state/sink/results ]]; then
  GOT=$(find state/sink/results -maxdepth 1 \
    -type f -name 'result_*.json' | wc -l)
else
  GOT=0
fi

if [[ "$FENCING" == 1 ]]; then
  EXPECT=1
else
  EXPECT=2
fi

if [[ "$GOT" -eq "$EXPECT" ]]; then
  VERDICT="OK"
else
  VERDICT="ПРОВЕРЬТЕ (ожидалось $EXPECT)"
fi

echo "      Принято результатов: $GOT, ожидалось: $EXPECT -> $VERDICT"

say "15. Сохраняю материалы эксперимента"

if [[ -d state/sink/results ]]; then
  mkdir -p "$OUT/accepted_results"
  cp -a state/sink/results/. "$OUT/accepted_results/"
fi

zk_exec get "/failover/$RUN_ID/epoch" \
  > "$OUT/zk_epoch.txt" 2>&1 || true

sed -i 's/^/ /' "$OUT/zk_epoch.txt"
cat "$OUT/zk_epoch.txt" | sed 's/^/      /'

say "16. Останавливаю координаторы и sink"

# FIX: kill вместо stop — не спотыкается о "improper"/paused.
run docker compose kill coord1 coord2 sink 2>/dev/null ||
  echo "      Предупреждение: не все контейнеры удалось остановить"

echo
echo "============================================================"
echo " ИТОГ ЭТАПА $STAGE"
echo "   смена лидера:          $SWITCH с после заморозки"
echo "   принято результатов:   $GOT (ожидалось $EXPECT) -> $VERDICT"
echo "   журналы и материалы:   $OUT/"
echo "============================================================"

sleep 1