#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$BASE_DIR/config/bg_boost.env"
PID_FILE="$BASE_DIR/state/bg_boost.pid"
LOCK_DIR="$BASE_DIR/state/bg_boost.lock"
STATE_FILE="$BASE_DIR/state/bg_boost.state"
LOG_FILE="$BASE_DIR/logs/bg_boost.log"

# Default runtime config (override in config/bg_boost.env)
SCAN_INTERVAL_SEC=2
TARGET_NICE=-10
TARGET_OOM_ADJ=-700
SAFE_CPU_PERCENT=90
SAFE_RAM_PERCENT=92
SAFE_TARGET_NICE=-2
SAFE_TARGET_OOM_ADJ=0
MAX_APPS_PER_CYCLE=40

# Comma-separated prefixes to skip, e.g. android,com.android,com.termux
IGNORE_PREFIXES="android,com.android"

# Runtime state
PREV_CPU_TOTAL=0
PREV_CPU_IDLE=0

ts_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  local ts
  ts="$(ts_utc)"
  mkdir -p "$(dirname "$LOG_FILE")" >/dev/null 2>&1 || true
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    . "$ENV_FILE"
  fi
}

require_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
}

run_root() {
  local cmd="$1"
  su -c "$cmd" >/dev/null 2>&1
}

check_root() {
  local uid
  uid="$(su -c 'id -u' 2>/dev/null || echo 9999)"
  [[ "$uid" == "0" ]] || die "Root access via su is required."
}

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

acquire_lock() {
  mkdir -p "$BASE_DIR/state" "$BASE_DIR/logs" "$BASE_DIR/config"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi
  die "Another instance appears to be running (lock exists: $LOCK_DIR)."
}

release_lock() {
  rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
}

cleanup() {
  rm -f "$PID_FILE" >/dev/null 2>&1 || true
  release_lock
}

cpu_percent() {
  local line user nice sys idle iowait irq softirq steal guest guest_nice
  read -r line user nice sys idle iowait irq softirq steal guest guest_nice < /proc/stat

  local idle_all total delta_total delta_idle usage
  idle_all=$((idle + iowait))
  total=$((user + nice + sys + idle + iowait + irq + softirq + steal))

  if (( PREV_CPU_TOTAL == 0 )); then
    PREV_CPU_TOTAL=$total
    PREV_CPU_IDLE=$idle_all
    echo 0
    return
  fi

  delta_total=$((total - PREV_CPU_TOTAL))
  delta_idle=$((idle_all - PREV_CPU_IDLE))

  PREV_CPU_TOTAL=$total
  PREV_CPU_IDLE=$idle_all

  if (( delta_total <= 0 )); then
    echo 0
    return
  fi

  usage=$(( (100 * (delta_total - delta_idle)) / delta_total ))
  (( usage < 0 )) && usage=0
  (( usage > 100 )) && usage=100
  echo "$usage"
}

ram_percent() {
  local mem_total mem_avail
  mem_total="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  mem_avail="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"

  if [[ -z "$mem_total" || -z "$mem_avail" || "$mem_total" == "0" ]]; then
    echo 0
    return
  fi

  echo $(( (100 * (mem_total - mem_avail)) / mem_total ))
}

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  echo "$s"
}

is_ignored_pkg() {
  local pkg="$1"
  local oldifs="$IFS"
  IFS=','
  local p
  for p in $IGNORE_PREFIXES; do
    p="$(trim "$p")"
    [[ -z "$p" ]] && continue
    if [[ "$pkg" == "$p" || "$pkg" == "$p."* ]]; then
      IFS="$oldifs"
      return 0
    fi
  done
  IFS="$oldifs"
  return 1
}

foreground_package() {
  local pkg

  pkg="$(dumpsys window 2>/dev/null | awk '/mCurrentFocus/ {print $0}' | sed -n 's/.* \([^ ]*\)\/[^ ]*.*/\1/p' | tail -n 1)"
  if [[ -n "$pkg" && "$pkg" == *.* ]]; then
    echo "$pkg"
    return
  fi

  pkg="$(dumpsys activity activities 2>/dev/null | awk '/mResumedActivity/ {print $0}' | sed -n 's/.* \([^ ]*\)\/[^ ]*.*/\1/p' | tail -n 1)"
  if [[ -n "$pkg" && "$pkg" == *.* ]]; then
    echo "$pkg"
    return
  fi

  echo ""
}

list_running_packages() {
  # Parse package-like names from process table.
  ps -A 2>/dev/null | awk 'NR>1 {print $NF}' | awk '/\./' | sort -u
}

optimize_pkg_pids() {
  local pkg="$1"
  local nice_val="$2"
  local oom_adj="$3"

  local pids
  pids="$(pidof "$pkg" 2>/dev/null || true)"
  [[ -z "$pids" ]] && return 1

  local pid
  for pid in $pids; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    run_root "renice -n $nice_val -p $pid"
    run_root "echo $oom_adj > /proc/$pid/oom_score_adj"
  done

  return 0
}

write_state() {
  local cpu_now="$1"
  local ram_now="$2"
  local fg_pkg="$3"
  local scanned="$4"
  local tuned="$5"
  local nice_val="$6"
  local oom_adj="$7"

  {
    echo "timestamp_utc=$(ts_utc)"
    echo "cpu_percent=$cpu_now"
    echo "ram_percent=$ram_now"
    echo "foreground_package=$fg_pkg"
    echo "scanned_packages=$scanned"
    echo "optimized_packages=$tuned"
    echo "target_nice=$nice_val"
    echo "target_oom_adj=$oom_adj"
    echo "scan_interval_sec=$SCAN_INTERVAL_SEC"
  } > "$STATE_FILE"
}

run_cycle() {
  local cpu_now ram_now fg_pkg
  cpu_now="$(cpu_percent)"
  ram_now="$(ram_percent)"
  fg_pkg="$(foreground_package)"

  local nice_val="$TARGET_NICE"
  local oom_adj="$TARGET_OOM_ADJ"
  local safe_mode=0
  if (( cpu_now >= SAFE_CPU_PERCENT || ram_now >= SAFE_RAM_PERCENT )); then
    safe_mode=1
    nice_val="$SAFE_TARGET_NICE"
    oom_adj="$SAFE_TARGET_OOM_ADJ"
  fi

  local scanned=0 tuned=0
  local pkg
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    [[ "$pkg" == "$fg_pkg" ]] && continue
    is_ignored_pkg "$pkg" && continue

    ((scanned++))
    if optimize_pkg_pids "$pkg" "$nice_val" "$oom_adj"; then
      ((tuned++))
    fi

    if (( scanned >= MAX_APPS_PER_CYCLE )); then
      break
    fi
  done < <(list_running_packages)

  write_state "$cpu_now" "$ram_now" "$fg_pkg" "$scanned" "$tuned" "$nice_val" "$oom_adj"
  log "cycle cpu=${cpu_now}% ram=${ram_now}% safe_mode=${safe_mode} fg=${fg_pkg:-none} scanned=${scanned} optimized=${tuned} nice=${nice_val} oom=${oom_adj}"
}

daemon_loop() {
  trap cleanup EXIT INT TERM
  acquire_lock
  echo "$$" > "$PID_FILE"
  log "Auto optimizer daemon started (pid=$$)"

  while true; do
    run_cycle
    sleep "$SCAN_INTERVAL_SEC"
  done
}

start_daemon() {
  if is_running; then
    echo "Already running (pid=$(cat "$PID_FILE"))"
    return
  fi

  nohup "$0" run >/dev/null 2>&1 &
  sleep 0.4

  if is_running; then
    echo "Started (pid=$(cat "$PID_FILE"))"
  else
    echo "Failed to start"
    return 1
  fi
}

stop_daemon() {
  if ! is_running; then
    echo "Already stopped"
    return
  fi

  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid" 2>/dev/null || true

  local i
  for i in 1 2 3 4 5; do
    sleep 0.3
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi

  cleanup
  echo "Stopped"
}

status_daemon() {
  if is_running; then
    echo "Running (pid=$(cat "$PID_FILE"))"
  else
    echo "Stopped"
  fi

  if [[ -f "$STATE_FILE" ]]; then
    echo "--- Last state ---"
    sed -n '1,160p' "$STATE_FILE"
  fi
}

validate_setup() {
  load_env
  require_cmd su
  require_cmd ps
  require_cmd awk
  require_cmd sed
  require_cmd pidof
  require_cmd renice
  check_root
}

usage() {
  cat <<USAGE
Usage: $0 [run|start|stop|status|once]

Commands:
  run       Run foreground auto optimizer loop
  start     Start background daemon
  stop      Stop daemon
  status    Show status and last cycle state
  once      Run exactly one optimization cycle

No argument defaults to: run
USAGE
}

main() {
  validate_setup

  local cmd="${1:-run}"
  case "$cmd" in
    run)
      daemon_loop
      ;;
    start)
      start_daemon
      ;;
    stop)
      stop_daemon
      ;;
    status)
      status_daemon
      ;;
    once)
      run_cycle
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
