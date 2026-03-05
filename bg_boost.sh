#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$BASE_DIR/config/bg_boost.env"
APPS_FILE="$BASE_DIR/config/priority_apps.conf"
WEBHOOKS_FILE="$BASE_DIR/config/discord_webhooks.conf"
PID_FILE="$BASE_DIR/state/bg_boost.pid"
LOCK_DIR="$BASE_DIR/state/bg_boost.lock"
STATE_FILE="$BASE_DIR/state/bg_boost.state"

# Defaults (can be overridden by bg_boost.env)
DISCORD_WEBHOOK_URL=""
CPU_CEILING_PERCENT=85
RAM_CEILING_PERCENT=85
SCAN_INTERVAL_SEC=2
CRASH_GRACE_SEC=8
NON_TARGET_NICE=8
TARGET_NICE=-12
TARGET_OOM_FALLBACK=-700
LOG_FILE="$BASE_DIR/logs/bg_boost.log"
SAFEGUARD_RELEASE_STREAK=3
NON_TARGET_OOM_ADJ=300
CGROUP_TARGET_TASKS=""
CGROUP_BG_TASKS=""
DASHBOARD_REFRESH_SEC=1
NET_IFACE=""
MENU_PAGE_SIZE=20
STATUS_WARN_CPU=75
STATUS_WARN_RAM=75

# Runtime state
SAFEGUARD_MODE=0
HEALTHY_STREAK=0
PREV_CPU_TOTAL=0
PREV_CPU_IDLE=0
NET_PREV_RX=0
NET_PREV_TX=0
NET_PREV_TS=0
NET_LAST_IFACE=""

# ANSI colors
C_RESET='\033[0m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_CYAN='\033[36m'
C_BOLD='\033[1m'

declare -A APP_MODE
declare -A APP_CPU_WEIGHT
declare -A APP_OOM_ADJ
declare -A LAST_PIDS
declare -A LAST_SEEN_TS
declare -A ALERT_SENT
declare -a APP_LIST
declare -A WEBHOOK_SET

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
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

detect_cgroup_paths() {
  local p
  CGROUP_TARGET_TASKS=""
  CGROUP_BG_TASKS=""

  for p in \
    /dev/stune/top-app/tasks \
    /dev/cpuctl/top-app/tasks \
    /dev/cpuset/top-app/tasks; do
    if [[ -w "$p" ]]; then
      CGROUP_TARGET_TASKS="$p"
      break
    fi
  done

  for p in \
    /dev/stune/background/tasks \
    /dev/cpuctl/background/tasks \
    /dev/cpuset/background/tasks; do
    if [[ -w "$p" ]]; then
      CGROUP_BG_TASKS="$p"
      break
    fi
  done
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

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  echo "$s"
}

valid_package() {
  [[ "$1" =~ ^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$ ]]
}

valid_webhook() {
  [[ "$1" =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/ ]]
}

parse_apps() {
  [[ -f "$APPS_FILE" ]] || die "Missing apps config: $APPS_FILE"

  APP_LIST=()
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line pkg mode cpuw oom
    line="${raw_line%%#*}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue

    IFS='|' read -r pkg mode cpuw oom <<< "$line"
    pkg="$(trim "${pkg:-}")"
    mode="$(trim "${mode:-boost}")"
    cpuw="$(trim "${cpuw:-85}")"
    oom="$(trim "${oom:-$TARGET_OOM_FALLBACK}")"

    [[ -z "$pkg" ]] && continue
    valid_package "$pkg" || continue

    APP_LIST+=("$pkg")
    APP_MODE["$pkg"]="$mode"
    APP_CPU_WEIGHT["$pkg"]="$cpuw"
    APP_OOM_ADJ["$pkg"]="$oom"
    LAST_PIDS["$pkg"]=""
    LAST_SEEN_TS["$pkg"]=0
    ALERT_SENT["$pkg"]=0
  done < "$APPS_FILE"
}

save_apps() {
  mkdir -p "$BASE_DIR/config"
  {
    echo "# package_name|mode|cpu_weight|oom_adj"
    echo "# oom_adj range: -1000 (most protected) .. 1000 (most killable)"
    local pkg
    for pkg in "${APP_LIST[@]}"; do
      echo "$pkg|${APP_MODE[$pkg]:-boost}|${APP_CPU_WEIGHT[$pkg]:-85}|${APP_OOM_ADJ[$pkg]:-$TARGET_OOM_FALLBACK}"
    done
  } > "$APPS_FILE"
}

load_webhooks() {
  WEBHOOK_SET=()

  if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
    local one
    one="$(trim "$DISCORD_WEBHOOK_URL")"
    if [[ -n "$one" ]] && valid_webhook "$one"; then
      WEBHOOK_SET["$one"]=1
    fi
  fi

  if [[ -f "$WEBHOOKS_FILE" ]]; then
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
      local line
      line="${raw_line%%#*}"
      line="$(trim "$line")"
      [[ -z "$line" ]] && continue
      valid_webhook "$line" || continue
      WEBHOOK_SET["$line"]=1
    done < "$WEBHOOKS_FILE"
  fi
}

save_webhooks_file() {
  mkdir -p "$BASE_DIR/config"
  {
    echo "# One Discord webhook URL per line"
    echo "# Format: https://discord.com/api/webhooks/..."
    local url
    for url in "${!WEBHOOK_SET[@]}"; do
      if [[ "$url" != "$DISCORD_WEBHOOK_URL" ]]; then
        echo "$url"
      fi
    done | sort
  } > "$WEBHOOKS_FILE"
}

webhook_count() {
  echo "${#WEBHOOK_SET[@]}"
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
  local mem_total mem_avail used
  mem_total="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  mem_avail="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"

  if [[ -z "$mem_total" || -z "$mem_avail" || "$mem_total" -le 0 ]]; then
    echo 0
    return
  fi

  used=$((mem_total - mem_avail))
  echo $(( (100 * used) / mem_total ))
}

auto_net_iface() {
  awk -F: 'NR>2 {gsub(/ /,"",$1); if ($1!="lo") print $1}' /proc/net/dev 2>/dev/null | head -n1
}

net_speed_kbs() {
  local iface now_ts rx tx delta_t down up
  iface="${NET_IFACE:-}"
  if [[ -z "$iface" ]]; then
    iface="$(auto_net_iface)"
  fi

  if [[ -z "$iface" ]]; then
    echo "0|0|none"
    return
  fi

  rx="$(awk -F'[: ]+' -v i="$iface" '$1==i {print $3}' /proc/net/dev 2>/dev/null)"
  tx="$(awk -F'[: ]+' -v i="$iface" '$1==i {print $11}' /proc/net/dev 2>/dev/null)"
  now_ts="$(date +%s)"

  if [[ -z "$rx" || -z "$tx" ]]; then
    echo "0|0|$iface"
    return
  fi

  if [[ "$NET_LAST_IFACE" != "$iface" || "$NET_PREV_TS" -eq 0 ]]; then
    NET_PREV_RX="$rx"
    NET_PREV_TX="$tx"
    NET_PREV_TS="$now_ts"
    NET_LAST_IFACE="$iface"
    echo "0|0|$iface"
    return
  fi

  delta_t=$((now_ts - NET_PREV_TS))
  if (( delta_t <= 0 )); then
    echo "0|0|$iface"
    return
  fi

  down=$(( (rx - NET_PREV_RX) / 1024 / delta_t ))
  up=$(( (tx - NET_PREV_TX) / 1024 / delta_t ))
  (( down < 0 )) && down=0
  (( up < 0 )) && up=0

  NET_PREV_RX="$rx"
  NET_PREV_TX="$tx"
  NET_PREV_TS="$now_ts"

  echo "$down|$up|$iface"
}

mbps_from_kbs() {
  local kbs="$1"
  awk -v v="$kbs" 'BEGIN {printf "%.2f", (v * 8.0) / 1000.0}'
}

status_label() {
  local val="$1" warn="$2" crit="$3"
  if (( val >= crit )); then
    printf "%bRED%b" "$C_RED" "$C_RESET"
  elif (( val >= warn )); then
    printf "%bYELLOW%b" "$C_YELLOW" "$C_RESET"
  else
    printf "%bGREEN%b" "$C_GREEN" "$C_RESET"
  fi
}

send_webhook() {
  local package="$1"
  local last_pids="$2"
  local cpu_now="$3"
  local ram_now="$4"

  load_webhooks
  if (( ${#WEBHOOK_SET[@]} == 0 )); then
    return 0
  fi

  require_cmd curl

  local host ts payload
  host="$(hostname 2>/dev/null || echo android-termux)"
  ts="$(ts_utc)"

  payload=$(cat <<JSON
{"username":"bg_boost","content":"[ALERT] App exited unexpectedly\\npackage: $package\\nlast_pid: $last_pids\\ntime_utc: $ts\\nhost: $host\\ncpu: ${cpu_now}%\\nram: ${ram_now}%"}
JSON
)

  local ok_count=0 fail_count=0 url ok
  for url in "${!WEBHOOK_SET[@]}"; do
    ok=0
    for _ in 1 2 3; do
      if curl -sS -m 8 -H 'Content-Type: application/json' -X POST -d "$payload" "$url" >/dev/null 2>&1; then
        ok=1
        break
      fi
      sleep 1
    done
    if (( ok == 1 )); then
      ((ok_count++))
    else
      ((fail_count++))
    fi
  done

  log "Webhook dispatch package=$package ok=$ok_count fail=$fail_count"
}

send_test_webhook() {
  load_webhooks
  if (( ${#WEBHOOK_SET[@]} == 0 )); then
    echo "No webhook configured"
    return 1
  fi
  send_webhook "test.package" "0000" "0" "0"
  echo "Test webhook dispatched"
}

resolve_pids_by_package() {
  local package="$1"
  local pids

  pids="$(pidof "$package" 2>/dev/null || true)"
  if [[ -z "$pids" ]]; then
    pids="$(ps -A 2>/dev/null | awk -v p="$package" '$NF==p {print $2}' | xargs 2>/dev/null || true)"
  fi

  echo "$pids"
}

is_core_system_process() {
  local name="$1"
  [[ "$name" == "system_server" ]] && return 0
  [[ "$name" == "surfaceflinger" ]] && return 0
  [[ "$name" == zygote* ]] && return 0
  [[ "$name" == "init" ]] && return 0
  [[ "$name" == "lmkd" ]] && return 0
  [[ "$name" == "servicemanager" ]] && return 0
  [[ "$name" == "hwservicemanager" ]] && return 0
  [[ "$name" == "vold" ]] && return 0
  [[ "$name" == "logd" ]] && return 0
  [[ "$name" == vendor.* ]] && return 0
  return 1
}

apply_target_tuning() {
  local pid="$1"
  local oom_adj="$2"
  local eff_target_nice="$TARGET_NICE"

  if (( SAFEGUARD_MODE == 1 )); then
    eff_target_nice=-4
    if (( oom_adj < -300 )); then
      oom_adj=-300
    fi
  fi

  run_root "renice -n $eff_target_nice -p $pid" || true
  if command -v ionice >/dev/null 2>&1; then
    run_root "ionice -c2 -n0 -p $pid" || true
  fi
  run_root "echo $oom_adj > /proc/$pid/oom_score_adj" || true
  if [[ -n "$CGROUP_TARGET_TASKS" ]]; then
    run_root "echo $pid > $CGROUP_TARGET_TASKS" || true
  fi
}

apply_non_target_tuning() {
  local pid="$1"
  run_root "renice -n $NON_TARGET_NICE -p $pid" || true
  run_root "echo $NON_TARGET_OOM_ADJ > /proc/$pid/oom_score_adj" || true
  if [[ -n "$CGROUP_BG_TASKS" ]]; then
    run_root "echo $pid > $CGROUP_BG_TASKS" || true
  fi
}

write_state() {
  local cpu_now="$1"
  local ram_now="$2"
  {
    echo "timestamp_utc=$(ts_utc)"
    echo "safeguard_mode=$SAFEGUARD_MODE"
    echo "cpu_percent=$cpu_now"
    echo "ram_percent=$ram_now"
    local pkg
    for pkg in "${APP_LIST[@]}"; do
      echo "app.$pkg.last_pids=${LAST_PIDS[$pkg]}"
      echo "app.$pkg.last_seen_ts=${LAST_SEEN_TS[$pkg]}"
      echo "app.$pkg.alert_sent=${ALERT_SENT[$pkg]}"
    done
  } > "$STATE_FILE"
}

collect_target_pid_map() {
  local -n out_map=$1
  out_map=()

  local pkg pids pid
  for pkg in "${APP_LIST[@]}"; do
    pids="$(resolve_pids_by_package "$pkg")"
    if [[ -n "$pids" ]]; then
      for pid in $pids; do
        out_map["$pid"]=1
      done
    fi
  done
}

scan_non_target_apps() {
  local -n target_map=$1

  ps -A 2>/dev/null | awk 'NR>1 {print $2"|"$NF}' | while IFS='|' read -r pid pname; do
    [[ -n "$pid" && -n "$pname" ]] || continue

    if [[ -n "${target_map[$pid]+x}" ]]; then
      continue
    fi

    [[ "$pname" == *.* ]] || continue
    if is_core_system_process "$pname"; then
      continue
    fi

    apply_non_target_tuning "$pid"
  done
}

handle_app_health() {
  local pkg="$1"
  local pids="$2"
  local now_ts="$3"
  local cpu_now="$4"
  local ram_now="$5"

  if [[ -n "$pids" ]]; then
    LAST_PIDS["$pkg"]="$pids"
    LAST_SEEN_TS["$pkg"]="$now_ts"
    ALERT_SENT["$pkg"]=0
    return
  fi

  local known
  known="${LAST_PIDS[$pkg]}"
  [[ -n "$known" ]] || return

  local last_seen absent_for
  last_seen="${LAST_SEEN_TS[$pkg]:-0}"
  absent_for=$((now_ts - last_seen))

  if (( absent_for >= CRASH_GRACE_SEC )) && (( ALERT_SENT[$pkg] == 0 )); then
    send_webhook "$pkg" "$known" "$cpu_now" "$ram_now"
    ALERT_SENT["$pkg"]=1
    log "ALERT: package=$pkg disappeared after ${absent_for}s (last_pids=$known)"
  fi
}

run_cycle() {
  local cpu_now ram_now now_ts pkg pids oom_adj
  cpu_now="$(cpu_percent)"
  ram_now="$(ram_percent)"
  now_ts="$(date +%s)"

  if (( cpu_now > CPU_CEILING_PERCENT || ram_now > RAM_CEILING_PERCENT )); then
    SAFEGUARD_MODE=1
    HEALTHY_STREAK=0
  else
    ((HEALTHY_STREAK++))
    if (( HEALTHY_STREAK >= SAFEGUARD_RELEASE_STREAK )); then
      SAFEGUARD_MODE=0
    fi
  fi

  for pkg in "${APP_LIST[@]}"; do
    pids="$(resolve_pids_by_package "$pkg")"

    if [[ -n "$pids" ]]; then
      oom_adj="${APP_OOM_ADJ[$pkg]:-$TARGET_OOM_FALLBACK}"
      local pid
      for pid in $pids; do
        apply_target_tuning "$pid" "$oom_adj"
      done
    fi

    handle_app_health "$pkg" "$pids" "$now_ts" "$cpu_now" "$ram_now"
  done

  if (( SAFEGUARD_MODE == 0 )); then
    declare -A target_pid_map
    collect_target_pid_map target_pid_map
    scan_non_target_apps target_pid_map
  fi

  write_state "$cpu_now" "$ram_now"
  log "cycle cpu=${cpu_now}% ram=${ram_now}% safeguard=${SAFEGUARD_MODE} targets=${#APP_LIST[@]}"
}

run_loop() {
  trap cleanup EXIT INT TERM
  acquire_lock
  echo "$$" > "$PID_FILE"
  log "bg_boost daemon started (pid=$$)"

  while true; do
    run_cycle
    sleep "$SCAN_INTERVAL_SEC"
  done
}

start_daemon() {
  if is_running; then
    echo "Already running (pid=$(cat "$PID_FILE"))"
    return 0
  fi

  mkdir -p "$BASE_DIR/logs" "$BASE_DIR/state"
  nohup "$0" run >> "$LOG_FILE" 2>&1 &
  sleep 1

  if is_running; then
    echo "Started (pid=$(cat "$PID_FILE"))"
  else
    echo "Failed to start. Check log: $LOG_FILE"
    return 1
  fi
}

stop_daemon() {
  if ! is_running; then
    echo "Not running"
    rm -f "$PID_FILE" >/dev/null 2>&1 || true
    release_lock
    return 0
  fi

  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid" >/dev/null 2>&1 || true
  sleep 1
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi

  rm -f "$PID_FILE" >/dev/null 2>&1 || true
  release_lock
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
    sed -n '1,120p' "$STATE_FILE"
  fi
}

pause_enter() {
  printf "\nPress Enter to continue..."
  read -r _
}

list_apps_table() {
  parse_apps
  if (( ${#APP_LIST[@]} == 0 )); then
    echo "No apps configured."
    return
  fi
  local i=1 pkg
  printf "%s\n" "Configured target apps:"
  for pkg in "${APP_LIST[@]}"; do
    printf "  %2d) %s | mode=%s cpuw=%s oom=%s\n" "$i" "$pkg" "${APP_MODE[$pkg]}" "${APP_CPU_WEIGHT[$pkg]}" "${APP_OOM_ADJ[$pkg]}"
    ((i++))
  done
}

scan_running_packages() {
  ps -A 2>/dev/null | awk 'NR>1 {print $NF}' | awk '/\./' | sort -u | while IFS= read -r pname; do
    [[ -z "$pname" ]] && continue
    if is_core_system_process "$pname"; then
      continue
    fi
    echo "$pname"
  done
}

menu_scan_add() {
  parse_apps
  mapfile -t found < <(scan_running_packages)
  if (( ${#found[@]} == 0 )); then
    echo "No app-like running packages detected."
    pause_enter
    return
  fi

  echo "Running app packages:"
  local i
  for ((i=0; i<${#found[@]}; i++)); do
    local pkg="${found[$i]}" mark=""
    if [[ -n "${APP_MODE[$pkg]+x}" ]]; then
      mark=" [already added]"
    fi
    printf "  %2d) %s%s\n" "$((i+1))" "$pkg" "$mark"
  done
  echo
  printf "Enter indexes to add (space-separated, blank to cancel): "
  local picks
  read -r picks
  [[ -z "$picks" ]] && return

  local idx added=0
  for idx in $picks; do
    [[ "$idx" =~ ^[0-9]+$ ]] || continue
    if (( idx < 1 || idx > ${#found[@]} )); then
      continue
    fi
    local pkg="${found[$((idx-1))]}"
    if [[ -n "${APP_MODE[$pkg]+x}" ]]; then
      continue
    fi
    APP_LIST+=("$pkg")
    APP_MODE["$pkg"]="boost"
    APP_CPU_WEIGHT["$pkg"]=85
    APP_OOM_ADJ["$pkg"]="$TARGET_OOM_FALLBACK"
    LAST_PIDS["$pkg"]=""
    LAST_SEEN_TS["$pkg"]=0
    ALERT_SENT["$pkg"]=0
    ((added++))
  done

  save_apps
  echo "Added $added app(s)."
  pause_enter
}

menu_add_manual_app() {
  parse_apps
  printf "Enter package name (e.g. com.game.example): "
  local pkg
  read -r pkg
  pkg="$(trim "$pkg")"

  if ! valid_package "$pkg"; then
    echo "Invalid package format."
    pause_enter
    return
  fi

  if [[ -n "${APP_MODE[$pkg]+x}" ]]; then
    echo "Package already exists in config."
    pause_enter
    return
  fi

  APP_LIST+=("$pkg")
  APP_MODE["$pkg"]="boost"
  APP_CPU_WEIGHT["$pkg"]=85
  APP_OOM_ADJ["$pkg"]="$TARGET_OOM_FALLBACK"
  LAST_PIDS["$pkg"]=""
  LAST_SEEN_TS["$pkg"]=0
  ALERT_SENT["$pkg"]=0
  save_apps

  echo "Added: $pkg"
  pause_enter
}

menu_remove_app() {
  parse_apps
  if (( ${#APP_LIST[@]} == 0 )); then
    echo "No configured apps to remove."
    pause_enter
    return
  fi

  list_apps_table
  echo
  printf "Enter index to remove (blank to cancel): "
  local idx
  read -r idx
  [[ -z "$idx" ]] && return
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#APP_LIST[@]} )); then
    echo "Invalid index"
    pause_enter
    return
  fi

  local remove_pkg="${APP_LIST[$((idx-1))]}"
  local -a new_list=()
  local pkg
  for pkg in "${APP_LIST[@]}"; do
    if [[ "$pkg" != "$remove_pkg" ]]; then
      new_list+=("$pkg")
    fi
  done
  APP_LIST=("${new_list[@]}")
  unset APP_MODE["$remove_pkg"] APP_CPU_WEIGHT["$remove_pkg"] APP_OOM_ADJ["$remove_pkg"]
  unset LAST_PIDS["$remove_pkg"] LAST_SEEN_TS["$remove_pkg"] ALERT_SENT["$remove_pkg"]

  save_apps
  echo "Removed: $remove_pkg"
  pause_enter
}

menu_list_webhooks() {
  load_webhooks
  if (( ${#WEBHOOK_SET[@]} == 0 )); then
    echo "No webhooks configured"
    pause_enter
    return
  fi
  echo "Configured webhooks:"
  local i=1 url
  for url in "${!WEBHOOK_SET[@]}"; do
    local masked="$url"
    if ((${#url} > 40)); then
      masked="${url:0:28}...${url: -8}"
    fi
    printf "  %2d) %s\n" "$i" "$masked"
    ((i++))
  done | sort
  pause_enter
}

menu_add_webhook() {
  load_webhooks
  printf "Enter Discord webhook URL: "
  local url
  read -r url
  url="$(trim "$url")"

  if ! valid_webhook "$url"; then
    echo "Invalid Discord webhook URL"
    pause_enter
    return
  fi

  WEBHOOK_SET["$url"]=1
  save_webhooks_file
  echo "Webhook added"
  pause_enter
}

menu_remove_webhook() {
  load_webhooks
  if (( ${#WEBHOOK_SET[@]} == 0 )); then
    echo "No webhooks configured"
    pause_enter
    return
  fi

  local -a urls=()
  local i=1 url
  for url in "${!WEBHOOK_SET[@]}"; do
    urls+=("$url")
    local masked="$url"
    if ((${#url} > 40)); then
      masked="${url:0:28}...${url: -8}"
    fi
    printf "  %2d) %s\n" "$i" "$masked"
    ((i++))
  done

  printf "Enter index to remove (blank to cancel): "
  local idx
  read -r idx
  [[ -z "$idx" ]] && return
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#urls[@]} )); then
    echo "Invalid index"
    pause_enter
    return
  fi

  unset WEBHOOK_SET["${urls[$((idx-1))]}"]
  save_webhooks_file
  echo "Webhook removed"
  pause_enter
}

menu_quick_settings() {
  printf "Current CPU ceiling (%s). Enter new value 50-95 (blank keep): " "$CPU_CEILING_PERCENT"
  local v1
  read -r v1
  printf "Current RAM ceiling (%s). Enter new value 50-95 (blank keep): " "$RAM_CEILING_PERCENT"
  local v2
  read -r v2

  if [[ -n "$v1" && "$v1" =~ ^[0-9]+$ ]] && (( v1 >= 50 && v1 <= 95 )); then
    CPU_CEILING_PERCENT="$v1"
  fi
  if [[ -n "$v2" && "$v2" =~ ^[0-9]+$ ]] && (( v2 >= 50 && v2 <= 95 )); then
    RAM_CEILING_PERCENT="$v2"
  fi

  if [[ -f "$ENV_FILE" ]]; then
    sed -i "s/^CPU_CEILING_PERCENT=.*/CPU_CEILING_PERCENT=$CPU_CEILING_PERCENT/" "$ENV_FILE" 2>/dev/null || true
    sed -i "s/^RAM_CEILING_PERCENT=.*/RAM_CEILING_PERCENT=$RAM_CEILING_PERCENT/" "$ENV_FILE" 2>/dev/null || true
  fi

  echo "Ceilings updated."
  pause_enter
}

menu_tail_log() {
  echo "--- Last 40 log lines ---"
  tail -n 40 "$LOG_FILE" 2>/dev/null || echo "No log file yet"
  pause_enter
}

render_dashboard() {
  local cpu_now ram_now net down up down_mbps up_mbps iface daemon_state guard_state
  cpu_now="$(cpu_percent)"
  ram_now="$(ram_percent)"
  net="$(net_speed_kbs)"
  down="${net%%|*}"
  net="${net#*|}"
  up="${net%%|*}"
  iface="${net##*|}"
  down_mbps="$(mbps_from_kbs "$down")"
  up_mbps="$(mbps_from_kbs "$up")"

  daemon_state="stopped"
  if is_running; then
    daemon_state="running pid=$(cat "$PID_FILE")"
  fi

  if [[ -f "$STATE_FILE" ]]; then
    guard_state="$(awk -F= '/^safeguard_mode=/ {print $2}' "$STATE_FILE" 2>/dev/null)"
    [[ -z "$guard_state" ]] && guard_state="$SAFEGUARD_MODE"
  else
    guard_state="$SAFEGUARD_MODE"
  fi

  parse_apps
  load_webhooks

  clear
  printf "%b%s%b\n" "$C_BOLD$C_CYAN" "BG Boost Control Center" "$C_RESET"
  echo "Time UTC: $(ts_utc)"
  echo "Daemon: $daemon_state"
  echo "Safeguard: $guard_state"
  printf "CPU: %s%% [%s]  ceiling=%s%%\n" "$cpu_now" "$(status_label "$cpu_now" "$STATUS_WARN_CPU" "$CPU_CEILING_PERCENT")" "$CPU_CEILING_PERCENT"
  printf "RAM: %s%% [%s]  ceiling=%s%%\n" "$ram_now" "$(status_label "$ram_now" "$STATUS_WARN_RAM" "$RAM_CEILING_PERCENT")" "$RAM_CEILING_PERCENT"
  printf "Net: ↓ %s Mbps ↑ %s Mbps iface=%s\n" "$down_mbps" "$up_mbps" "$iface"
  printf "Targets: %s | Webhooks: %s\n" "${#APP_LIST[@]}" "$(webhook_count)"

  echo
  echo "Shortcuts:"
  echo "  s=start  x=stop  o=once  a=scan+add  m=manual add  r=remove app"
  echo "  w=add webhook  d=delete webhook  l=list webhooks  t=test webhook"
  echo "  g=settings  p=show apps  n=tail log  q=quit"
  echo
  printf "Input (auto-refresh %ss): " "$DASHBOARD_REFRESH_SEC"
}

menu_loop() {
  validate_setup

  while true; do
    render_dashboard
    local key
    read -r -t "$DASHBOARD_REFRESH_SEC" key || continue

    case "$key" in
      s) start_daemon; pause_enter ;;
      x) stop_daemon; pause_enter ;;
      o) run_cycle; echo "One cycle executed"; pause_enter ;;
      a) menu_scan_add ;;
      m) menu_add_manual_app ;;
      r) menu_remove_app ;;
      p) clear; list_apps_table; pause_enter ;;
      w) menu_add_webhook ;;
      d) menu_remove_webhook ;;
      l) clear; menu_list_webhooks ;;
      t) send_test_webhook; pause_enter ;;
      g) menu_quick_settings ;;
      n) clear; menu_tail_log ;;
      q) clear; echo "Exiting menu"; break ;;
      *) ;;
    esac
  done
}

validate_setup() {
  load_env
  require_cmd su
  require_cmd pidof
  require_cmd ps
  require_cmd awk
  require_cmd sed
  require_cmd renice
  check_root
  detect_cgroup_paths
  parse_apps
  load_webhooks
}

usage() {
  cat <<USAGE
Usage: $0 {start|stop|status|once|run|menu|webhooks}

Commands:
  start      Start daemon in background
  stop       Stop daemon
  status     Show daemon status and last state
  once       Run exactly one tuning cycle (debug)
  run        Internal foreground daemon command
  menu       Open interactive multipurpose menu
  webhooks   List resolved webhook count and URLs
USAGE
}

cmd_list_webhooks() {
  load_env
  load_webhooks
  echo "Webhook count: ${#WEBHOOK_SET[@]}"
  local url
  for url in "${!WEBHOOK_SET[@]}"; do
    echo "$url"
  done | sort
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    start)
      validate_setup
      start_daemon
      ;;
    stop)
      stop_daemon
      ;;
    status)
      status_daemon
      ;;
    once)
      validate_setup
      run_cycle
      ;;
    run)
      validate_setup
      run_loop
      ;;
    menu)
      menu_loop
      ;;
    webhooks)
      cmd_list_webhooks
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
