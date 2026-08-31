#!/bin/sh
#
# Консервативный watchdog Plex Media Server для установки QPKG на QNAP.
# Запускается cron от root/admin, проверяет Plex только локально и действует,
# лишь когда QPKG включён, а краткая повторная проверка не восстановила здоровье.

QPKG_NAME="PlexMediaServer"
# Путь жёстко привязан к целевому тому QNAP и потому не является переносимым.
QPKG_DIR="/share/CACHEDEV1_DATA/.qpkg/PlexMediaServer"
# Конфигурация QPKG служит единственным источником решения, разрешён ли сервис.
CONFIG="/etc/config/qpkg.conf"
PMS_BIN="${QPKG_DIR}/Plex Media Server"
# Все постоянные диагностические файлы остаются рядом с журналами Plex.
LOG="${QPKG_DIR}/Library/Plex Media Server/Logs/plex-watchdog.log"
# Состояние подавляет повторяющиеся записи о неизменившемся результате проверки.
STATE="${QPKG_DIR}/Library/Plex Media Server/Logs/plex-watchdog.state"
# Отдельная отметка времени ограничивает частоту циклов из-за зависшего маршрута.
ROUTE_STATE="${QPKG_DIR}/Library/Plex Media Server/Logs/plex-watchdog.route-restart"
PMS_LOG="${QPKG_DIR}/Library/Plex Media Server/Logs/Plex Media Server.log"
# Каталог в /tmp даёт простую атомарную блокировку между параллельными запусками cron.
LOCK="/tmp/plex-watchdog.lock"
# После загрузки NAS Plex получает время на штатную инициализацию без вмешательства.
BOOT_GRACE_SECONDS=600
# Повторный цикл для маршрута разрешён редко, чтобы не создавать рестарт-шторм.
ROUTE_COOLDOWN_SECONDS=43200
ROUTE_ERROR_TAIL_LINES=250
# Устаревшая блокировка не должна навсегда отключить watchdog после аварийного выхода.
STALE_LOCK_SECONDS=900
# Внешние QPKG-команды ограничены по времени, чтобы cron не завис бесконечно.
QPkg_TIMEOUT_SECONDS=180

# Фиксированный PATH не зависит от окружения, с которым cron запускает скрипт.
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

log_msg() {
  msg="$*"
  ts="$(date '+%Y-%m-%d %H:%M:%S %z')"
  printf '%s %s\n' "$ts" "$msg" >> "$LOG"
}

log_event() {
# Помимо файла, событие передаётся в системный журнал QNAP; его сбой не меняет исход проверки.
  log_msg "$*"
  /sbin/log_tool -t 1 -a "Plex watchdog: $*" >/dev/null 2>&1 || true
}

set_state() {
# В файле хранится только последнее логическое состояние, а не журнал истории.
  printf '%s\n' "$1" > "$STATE"
}

get_state() {
# Отсутствие или ошибка чтения состояния безопасно трактуется как неизвестное предыдущее состояние.
  [ -f "$STATE" ] && cat "$STATE" 2>/dev/null || true
}

uptime_seconds() {
# Время работы ядра нужно только для защитного окна сразу после загрузки NAS.
  awk -F. '{print $1}' /proc/uptime 2>/dev/null || echo 0
}

pms_pid() {
  ps -ef | grep "$PMS_BIN" | grep -v grep | awk 'NR == 1 {print $1}'
}

pms_http_ok() {
# Локальный HTTP без токена проверяет доступность сервера, не раскрывая учётные данные.
  curl -fsS -m 5 -I http://127.0.0.1:32400/web/index.html >/dev/null 2>&1
}

active_nonlocal_clients() {
# Активные не-loopback подключения защищают пользователей от рестарта во время просмотра.
  netstat -tn 2>/dev/null \
    | awk '$4 ~ /:32400$/ && $6 == "ESTABLISHED" && $5 !~ /(127\.0\.0\.1|::1)/ {found=1} END {exit found ? 0 : 1}'
}

now_epoch() {
  date +%s 2>/dev/null || echo 0
}

route_restart_allowed() {
# Некорректная или отсутствующая отметка считается нулевой, а не причиной отказа проверки.
  now="$(now_epoch)"
  last=0
  [ -f "$ROUTE_STATE" ] && last="$(cat "$ROUTE_STATE" 2>/dev/null || echo 0)"
  case "$last" in
    ''|*[!0-9]*) last=0 ;;
  esac
  [ "$((now - last))" -ge "$ROUTE_COOLDOWN_SECONDS" ]
}

mark_route_restart() {
  now_epoch > "$ROUTE_STATE"
}

route_looks_stuck() {
# Сигнатуры в журнале указывают на проблему объявленного маршрута при живом локальном Plex.
  [ -f "$PMS_LOG" ] || return 1
  tail -n "$ROUTE_ERROR_TAIL_LINES" "$PMS_LOG" 2>/dev/null \
    | grep -Eq 'plex\.direct(:0| port 0)|not yet mapped'
}

pms_enabled() {
# Отключённый администратором QPKG никогда не запускается watchdogом самовольно.
  enabled="$(/sbin/getcfg "$QPKG_NAME" Enable -u -d FALSE -f "$CONFIG" 2>/dev/null || echo FALSE)"
  [ "$enabled" = "TRUE" ]
}

healthy() {
# Одного PID недостаточно: процесс может зависнуть до готовности HTTP-интерфейса.
  [ -n "$(pms_pid)" ] && pms_http_ok
}

wait_for_pid_gone() {
  i=0
  while [ "$i" -lt 12 ]; do
    [ -z "$(pms_pid)" ] && return 0
    sleep 5
    i=$((i + 1))
  done
  return 1
}

wait_for_healthy() {
# После запуска опрашивается реальный health check, а не только код возврата QPKG-команды.
  i=0
  while [ "$i" -lt 18 ]; do
    healthy && return 0
    sleep 5
    i=$((i + 1))
  done
  return 1
}

run_with_timeout() {
  secs="$1"; shift
  "$@" &
  pid=$!
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$secs" ]; do
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
# Сначала отправляется обычный сигнал, затем принудительный — только если процесс не завершился.
    kill "$pid" 2>/dev/null
    sleep 2
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    log_msg "timeout after ${secs}s: $*"
    return 124
  fi
  wait "$pid"
  return $?
}

qpkg_start() {
# На новых прошивках предпочтителен qpkg_cli; сохранен fallback для старого интерфейса QNAP.
  if [ -x /sbin/qpkg_cli ]; then
    run_with_timeout "$QPkg_TIMEOUT_SECONDS" /sbin/qpkg_cli --start "$QPKG_NAME"
  else
    run_with_timeout "$QPkg_TIMEOUT_SECONDS" /sbin/qpkg_service -t 90 start "$QPKG_NAME"
  fi
}

qpkg_stop() {
  if [ -x /sbin/qpkg_cli ]; then
    run_with_timeout "$QPkg_TIMEOUT_SECONDS" /sbin/qpkg_cli --stop "$QPKG_NAME"
  else
    run_with_timeout "$QPkg_TIMEOUT_SECONDS" /sbin/qpkg_service -t 90 stop "$QPKG_NAME"
  fi
}

cycle_plex() {
# При отсутствии PID нужен только start; при зависшем процессе выполняется полный stop/start.
  action="$1"
  if [ "$action" = "start" ]; then
    qpkg_start
    return $?
  fi

  qpkg_stop
  stop_rc=$?
  wait_for_pid_gone || true
  qpkg_start
  start_rc=$?
  [ "$stop_rc" -eq 0 ] && [ "$start_rc" -eq 0 ]
}

lock_is_stale() {
# Возраст блокировки вычисляется по mtime каталога, поэтому не требуется хранить отдельный PID.
  [ -d "$LOCK" ] || return 1
  lock_mtime="$(stat -c %Y "$LOCK" 2>/dev/null || echo 0)"
  now="$(now_epoch)"
  case "$lock_mtime" in
    ''|*[!0-9]*) lock_mtime=0 ;;
  esac
  [ "$lock_mtime" -gt 0 ] && [ "$((now - lock_mtime))" -ge "$STALE_LOCK_SECONDS" ]
}

if ! mkdir "$LOCK" 2>/dev/null; then
# Неактуальная блокировка убирается только после контролируемого таймаута, иначе запуск пропускается.
  if lock_is_stale; then
    log_msg "removing stale lock dir $LOCK"
    rmdir "$LOCK" 2>/dev/null || true
    if ! mkdir "$LOCK" 2>/dev/null; then
      exit 0
    fi
  else
    exit 0
  fi
fi
# trap освобождает блокировку при обычном выходе и при перехватываемых сигналах.
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT HUP INT TERM

# Если каталог Plex ещё не существует, писать состояние и выполнять действия небезопасно.
[ -d "$(dirname "$LOG")" ] || exit 0

if ! pms_enabled; then
  [ "$(get_state)" = "disabled" ] || log_msg "PlexMediaServer is disabled; watchdog idle"
  set_state "disabled"
  exit 0
fi

if healthy; then
# Маршрут проверяется только у локально здорового Plex: иначе причина уже покрыта обычным восстановлением.
  if route_looks_stuck && route_restart_allowed; then
    if active_nonlocal_clients; then
# При живых удалённых клиентах риск прерывания просмотра важнее исправления рекламируемого маршрута.
      current="route-stuck-active-clients"
      [ "$(get_state)" = "$current" ] || log_msg "Plex local HTTP healthy, route looks stuck, but active non-local clients exist; skipping cycle"
      set_state "$current"
      exit 0
    fi

# Перед циклом фиксируется cooldown, а его результат всё равно подтверждается health check после запуска.
    log_event "Plex local HTTP healthy but advertised route looks stuck; cycling QPKG with qpkg_cli"
    mark_route_restart
    cycle_plex restart >> "$LOG" 2>&1
    rc=$?

    if wait_for_healthy; then
      log_event "Plex healthy after route-stuck cycle pid=$(pms_pid) qpkg_rc=$rc"
      set_state "healthy"
    else
      log_event "Plex still unhealthy after route-stuck cycle qpkg_rc=$rc pid=$(pms_pid || true)"
      set_state "unhealthy"
    fi
    exit 0
  fi

# В нормальном состоянии запись делается только при смене состояния, чтобы журнал оставался читаемым.
  previous="$(get_state)"
  if [ "$previous" != "healthy" ]; then
    log_msg "Plex healthy pid=$(pms_pid)"
  fi
  set_state "healthy"
  exit 0
fi

# Короткая пауза защищает от рестарта из-за кратковременного сбоя локального HTTP.
sleep 15

if healthy; then
# Если Plex восстановился самостоятельно, управляющие команды QPKG не вызываются.
  log_msg "Plex recovered during retry pid=$(pms_pid)"
  set_state "healthy"
  exit 0
fi

uptime="$(uptime_seconds)"
pid="$(pms_pid)"

if [ "$uptime" -lt "$BOOT_GRACE_SECONDS" ]; then
# В boot grace фиксируется наблюдаемое состояние, но запуск или рестарт намеренно пропускается.
  current="boot-grace:${pid:-none}"
  if [ "$(get_state)" != "$current" ]; then
    log_msg "Plex unhealthy during boot grace uptime=${uptime}s pid=${pid:-none}; skipping action"
  fi
  set_state "$current"
  exit 0
fi

if [ -n "$pid" ]; then
# Выбор действия основан на PID: существующий, но нездоровый процесс перезапускается.
  action="restart"
  reason="process pid=$pid exists but HTTP health check failed"
else
  action="start"
  reason="no Plex Media Server process found"
fi

# Причина записывается до вызова QPKG, чтобы отличать старт отсутствующего процесса от рестарта зависшего.
log_event "running QPKG $action through qpkg_cli: $reason"
cycle_plex "$action" >> "$LOG" 2>&1
rc=$?

if wait_for_healthy; then
# Итоговое состояние отражает повторную проверку Plex, а не только успешность управляющей команды.
  log_event "Plex healthy after $action pid=$(pms_pid) qpkg_rc=$rc"
  set_state "healthy"
else
  log_event "Plex still unhealthy after $action qpkg_rc=$rc pid=$(pms_pid || true)"
  set_state "unhealthy"
fi

exit 0
