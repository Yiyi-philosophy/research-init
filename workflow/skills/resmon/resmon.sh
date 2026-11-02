#!/usr/bin/env bash
# resmon.sh — background resource monitor for one task on a remote (SSH) or local Linux machine.
#
# Controller side (where the agent runs): bash 3.2+ and awk.
# Target side: POSIX sh + awk + /proc. The probe is sent over stdin, is read-only,
# and writes no files on the target.
#
# Protocol: `start` launches a detached monitor and returns its handle as JSON.
# The monitor appends structured events to events.jsonl. The foreground agent
# blocks on (or polls) `wait`, reacts, records what it did with `note`, and
# calls `stop` when the task ends. See SKILL.md.
set -o pipefail

PROG=resmon.sh
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SELF="$SELF_DIR/$(basename "$0")"
RESMON_HOME=${RESMON_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/resmon}

usage() {
  cat <<'EOF'
Usage:
  resmon.sh start <machine|local> --task-id ID [TARGET] [OPTIONS]   launch background monitor, print handle JSON
  resmon.sh run   <machine|local> [--task-id ID] [TARGET] [OPTIONS] same loop in the foreground, events on stdout
  resmon.sh check <machine|local> [TARGET] [OPTIONS]                one sample, print JSON, exit 0/2/3/4
  resmon.sh wait   <monitor> [--timeout SEC] [--after SEQ] [--all]  block until an actionable event
  resmon.sh events <monitor> [--after SEQ] [--type T]               print events
  resmon.sh status <monitor>                                        latest state JSON
  resmon.sh note   <monitor> MESSAGE [--reset-baseline] [--pid PID] record an intervention (optionally retarget)
  resmon.sh stop   <monitor>|--all                                  stop monitor(s)
  resmon.sh list                                                    list monitors

<monitor> is a monitor_id, or a task id (picks its newest monitor).

TARGET (what the task-level limits apply to; pick one):
  --pid PID[,PID]      process tree(s) rooted at PID on the target machine
  --pid-file PATH      file on the target machine holding the root PID (re-read every sample)
  --cgroup PATH        cgroup v2 path (e.g. /user.slice/run-123.scope)
  Without a target only machine-level limits apply.

OPTIONS:
  --interval DUR       time between samples (default 30s; accepts s/m/h)
  --window SEC         CPU/IO measurement window inside each sample (default 1)
  --limit K=V[,K=V]    set limits; repeatable (0 disables a limit). Units accepted: %, GiB/MiB/TiB, MiB/s, ms
  --disk PATH[=PCT]    disk path to watch (repeatable; default /), optional used% limit for that path
  --ttl DUR            stop monitor after this long (default 24h, 0 = never)
  --stop-on-alert      stop the monitor after the first threshold event

Limits (--limit KEY=VALUE, default in brackets):
  task:    task_rss_gib[0] task_rss_pct[0] task_mem_limit_pct[90] task_rss_growth_gib_per_min[4]
           task_cpu_pct[0] (100 = one core) task_procs[0] task_threads[0] task_oom_new[1]
           task_read_mibps[0] task_write_mibps[0]
  machine: cpu_busy_pct[95] load_per_cpu[1.5] iowait_pct[0] mem_used_pct[85] swap_used_pct[40]
           psi_mem_full_avg10[5] psi_io_full_avg10[0] oom_kill_new[1]
  disk:    disk_used_pct[92] disk_inodes_pct[95] disk_util_pct[0] disk_await_ms[0]
           disk_read_mibps[0] disk_write_mibps[0]
  control: sustain[2] (samples in a row for rate metrics) realert[10] unreachable[3]
  aliases: cpu, load, iowait, swap, psi, task_cpu, task_mem, disk, disk_util, disk_await;
           memory=85% -> mem_used_pct, memory=64GiB -> task_rss_gib; disk=/data:92% -> per-path limit

Exit codes: 0 ok / nothing new, 1 usage or environment error, 2 threshold, 3 collection failure
            or unreachable, 4 target exited, 5 monitor stopped or died.
EOF
}

die() { echo "$PROG: $*" >&2; exit 1; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
# JSON helpers (shared by every awk program)
# ---------------------------------------------------------------------------
AWK_LIB='
function js(s,   i, n, c, o, p) {
  if (CTRL == "") for (i = 1; i < 32; i++) CTRL = CTRL sprintf("%c", i)
  o = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") o = o "\\\\"
    else if (c == "\"") o = o "\\\""
    else if ((p = index(CTRL, c)) > 0) {
      if (p == 10) o = o "\\n"; else if (p == 9) o = o "\\t"; else if (p == 13) o = o "\\r"
      else o = o sprintf("\\u%04x", p)
    } else o = o c
  }
  return "\"" o "\""
}
function num(x) {
  if (x == "" || x == "-") return "null"
  x = sprintf("%.2f", x); sub(/0+$/, "", x); sub(/\.$/, "", x)
  if (x == "-0") x = "0"
  return x
}
'

jstr() { S="$1" awk "$AWK_LIB"' BEGIN { printf "%s", js(ENVIRON["S"]) }'; }

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

parse_duration() {
  case $1 in ''|*[!0-9smhd]*) return 1 ;; esac
  local n=${1%[smhd]} u=${1##*[0-9]}
  case $n in ''|*[!0-9]*) return 1 ;; esac
  case $u in
    ''|s) echo "$n" ;;
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    d) echo $((n * 86400)) ;;
    *) return 1 ;;
  esac
}

is_uint() { case $1 in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LIMIT_KEYS="cpu_busy_pct load_per_cpu iowait_pct mem_used_pct swap_used_pct psi_mem_full_avg10 psi_io_full_avg10 oom_kill_new disk_used_pct disk_inodes_pct disk_util_pct disk_await_ms disk_read_mibps disk_write_mibps task_cpu_pct task_rss_gib task_rss_pct task_mem_limit_pct task_rss_growth_gib_per_min task_oom_new task_procs task_threads task_read_mibps task_write_mibps"

set_defaults() {
  L_cpu_busy_pct=95; L_load_per_cpu=1.5; L_iowait_pct=0; L_mem_used_pct=85; L_swap_used_pct=40
  L_psi_mem_full_avg10=5; L_psi_io_full_avg10=0; L_oom_kill_new=1
  L_disk_used_pct=92; L_disk_inodes_pct=95; L_disk_util_pct=0; L_disk_await_ms=0
  L_disk_read_mibps=0; L_disk_write_mibps=0
  L_task_cpu_pct=0; L_task_rss_gib=0; L_task_rss_pct=0; L_task_mem_limit_pct=90
  L_task_rss_growth_gib_per_min=4; L_task_oom_new=1; L_task_procs=0; L_task_threads=0
  L_task_read_mibps=0; L_task_write_mibps=0
  interval=30; window=1; sustain=2; realert=10; unreachable=3; ttl=86400; stop_on_alert=0
  MACHINE=""; TASK_ID=""; TKIND=none; TPIDS=""; TPIDFILE=""; TCGROUP=""
  DISK_PATHS=(); DISK_LIMS=()
}

# Normalise a limit value to the key's base unit; fails on junk or wrong unit.
normalize_value() {
  awk -v k="$1" -v v="$2" 'BEGIN {
    s = v; gsub(/[ \t]/, "", s)
    if (!match(s, /^[0-9]*\.?[0-9]+/)) exit 1
    n = substr(s, 1, RLENGTH); u = tolower(substr(s, RLENGTH + 1)); m = -1
    if (k ~ /_gib$/ || k ~ /_gib_per_min$/) {
      sub(/\/min$/, "", u)
      if (u == "" || u ~ /^(g|gb|gib)$/) m = 1; else if (u ~ /^(m|mb|mib)$/) m = 1 / 1024; else if (u ~ /^(t|tb|tib)$/) m = 1024
    } else if (k ~ /_mibps$/) {
      sub(/\/s$/, "", u); sub(/ps$/, "", u)
      if (u == "" || u ~ /^(m|mb|mib)$/) m = 1; else if (u ~ /^(g|gb|gib)$/) m = 1024; else if (u ~ /^(k|kb|kib)$/) m = 1 / 1024
    } else if (k ~ /_ms$/) {
      if (u == "" || u == "ms") m = 1; else if (u == "s") m = 1000
    } else if (k ~ /_pct$/ || k ~ /_avg10$/) {
      if (u == "" || u == "%") m = 1
    } else if (u == "") m = 1
    if (m < 0) exit 1
    printf "%.6g\n", n * m
  }'
}

add_disk() {
  local path=$1 pct=$2 i
  case $path in /*) ;; *) die "disk path must be absolute: '$path'" ;; esac
  if [ -n "$pct" ]; then pct=$(normalize_value disk_used_pct "$pct") || die "bad disk limit for $path: '$2'"; fi
  i=0
  while [ "$i" -lt "${#DISK_PATHS[@]}" ]; do
    if [ "${DISK_PATHS[$i]}" = "$path" ]; then DISK_LIMS[$i]=$pct; return; fi
    i=$((i + 1))
  done
  DISK_PATHS[$i]=$path; DISK_LIMS[$i]=$pct
}

set_limit() {
  local key=$1 raw=$2 v
  [ -n "$raw" ] || die "empty value for '$key'"
  case $key in
    cpu) key=cpu_busy_pct ;;
    load) key=load_per_cpu ;;
    iowait) key=iowait_pct ;;
    swap) key=swap_used_pct ;;
    psi|psi_full_avg10) key=psi_mem_full_avg10 ;;
    task_cpu) key=task_cpu_pct ;;
    task_mem|task_rss|task_memory) key=task_rss_gib ;;
    disk|disk_used) key=disk_used_pct ;;
    disk_util) key=disk_util_pct ;;
    disk_await) key=disk_await_ms ;;
    mem|memory)
      case $raw in *%|*[0-9]) key=mem_used_pct ;; *) key=task_rss_gib ;; esac ;;
  esac
  case $key in
    interval) interval=$(parse_duration "$raw") || die "bad interval '$raw'"; return ;;
    ttl) ttl=$(parse_duration "$raw") || die "bad ttl '$raw'"; return ;;
    window|sustain|realert|unreachable)
      is_uint "$raw" && [ "$raw" -ge 1 ] || die "$key must be an integer >= 1 (got '$raw')"
      eval "$key=\$raw"; return ;;
  esac
  if [ "$key" = disk_used_pct ]; then
    case $raw in /*:*) add_disk "${raw%:*}" "${raw##*:}"; return ;; /*) add_disk "$raw" ""; return ;; esac
  fi
  case " $LIMIT_KEYS " in *" $key "*) ;; *) die "unknown limit '$key' (see --help)" ;; esac
  v=$(normalize_value "$key" "$raw") || die "bad value for $key: '$raw' (expected a number with a unit fitting $key)"
  eval "L_$key=\$v"
}

apply_limits() { # "k=v,k=v"
  local list=$1 item
  local IFS=,
  for item in $list; do
    [ -n "$item" ] || continue
    case $item in *=*) ;; *) die "limit must be KEY=VALUE (got '$item')" ;; esac
    set_limit "${item%%=*}" "${item#*=}"
  done
}

parse_monitor_args() { # sets globals; $1 = mode (start|run|check)
  local mode=$1; shift
  set_defaults
  [ -n "${RESMON_LIMITS:-}" ] && apply_limits "$RESMON_LIMITS"
  while [ $# -gt 0 ]; do
    case $1 in
      --task-id|--pid|--pid-file|--cgroup|--interval|--window|--limit|--set|--disk|--ttl)
        [ $# -ge 2 ] && [ -n "$2" ] || die "$1 requires a value" ;;
    esac
    case $1 in
      -h|--help) usage; exit 0 ;;
      --task-id) TASK_ID=$2; shift 2 ;;
      --pid)
        case $2 in *[!0-9,]*|,*|*,|*,,*) die "--pid expects PID[,PID] (got '$2')" ;; esac
        [ "$TKIND" = none ] || [ "$TKIND" = pid -a -z "$TPIDFILE" ] || die "use only one of --pid, --pid-file, --cgroup"
        TKIND=pid; TPIDS="${TPIDS:+$TPIDS }$(printf '%s' "$2" | tr ',' ' ')"; shift 2 ;;
      --pid-file)
        [ "$TKIND" = none ] || die "use only one of --pid, --pid-file, --cgroup"
        TKIND=pid; TPIDFILE=$2; shift 2 ;;
      --cgroup)
        [ "$TKIND" = none ] || die "use only one of --pid, --pid-file, --cgroup"
        case $2 in *..*) die "--cgroup path must not contain '..'" ;; esac
        TKIND=cgroup; TCGROUP=$2; shift 2 ;;
      --interval) interval=$(parse_duration "$2") || die "bad --interval '$2'"; shift 2 ;;
      --window) set_limit window "$2"; shift 2 ;;
      --ttl) ttl=$(parse_duration "$2") || die "bad --ttl '$2'"; shift 2 ;;
      --limit|--set) apply_limits "$2"; shift 2 ;;
      --disk)
        case $2 in
          *=*) local dp=${2%=*} dv=${2##*=}
               if normalize_value disk_used_pct "$dv" >/dev/null 2>&1; then add_disk "$dp" "$dv"; else add_disk "$2" ""; fi ;;
          *) add_disk "$2" "" ;;
        esac
        shift 2 ;;
      --stop-on-alert) stop_on_alert=1; shift ;;
      -*) die "unknown option '$1' (see --help)" ;;
      *) [ -z "$MACHINE" ] || die "unexpected argument '$1'"; MACHINE=$1; shift ;;
    esac
  done
  [ -n "$MACHINE" ] || die "missing <machine|local>"
  [ "$interval" -ge $((window + 1)) ] 2>/dev/null || die "interval ($interval s) must exceed window ($window s)"
  [ "$window" -le 30 ] || die "window must be <= 30"
  if [ "$mode" = start ] && [ -z "$TASK_ID" ]; then die "start requires --task-id"; fi
  [ -n "$TASK_ID" ] || TASK_ID=adhoc
  [ "${#DISK_PATHS[@]}" -gt 0 ] || add_disk / ""
  if [ "$MACHINE" = local ] && [ -z "${RESMON_COLLECT_CMD:-}" ] && [ -z "${RESMON_TEST_ROOT:-}" ] \
     && [ "$(uname -s)" != Linux ]; then
    die "'local' needs a Linux host with /proc; pass an SSH target instead"
  fi
  if [ "$MACHINE" != local ] && [ -z "${RESMON_COLLECT_CMD:-}" ]; then
    command -v ssh >/dev/null 2>&1 || die "ssh not found"
  fi
}

write_limits() { # $1 = file
  local k v i
  {
    for k in $LIMIT_KEYS; do eval "v=\$L_$k"; printf '%s %s\n' "$k" "$v"; done
    printf 'sustain %s\nrealert %s\n' "$sustain" "$realert"
    i=0
    while [ "$i" -lt "${#DISK_PATHS[@]}" ]; do
      printf 'disk_path %d %s\n' $((i + 1)) "${DISK_PATHS[$i]}"
      [ -n "${DISK_LIMS[$i]}" ] && printf 'disk_limit %d %s\n' $((i + 1)) "${DISK_LIMS[$i]}"
      i=$((i + 1))
    done
  } > "$1"
}

limits_json() {
  local k v out="" i
  for k in $LIMIT_KEYS; do
    eval "v=\$L_$k"
    awk -v v="$v" 'BEGIN { exit !(v + 0 > 0) }' && out="$out${out:+,}\"$k\":$v"
  done
  printf '{%s}' "$out"
}

disks_json() {
  local i=0 out="" lim
  while [ "$i" -lt "${#DISK_PATHS[@]}" ]; do
    lim=${DISK_LIMS[$i]:-$L_disk_used_pct}
    out="$out${out:+,}{\"path\":$(jstr "${DISK_PATHS[$i]}"),\"used_pct_limit\":$lim}"
    i=$((i + 1))
  done
  printf '[%s]' "$out"
}

target_json() {
  local roots="" p
  for p in $TPIDS; do roots="$roots${roots:+,}$p"; done
  case $TKIND in
    pid) if [ -n "$TPIDFILE" ]; then printf '{"kind":"pid","pid_file":%s}' "$(jstr "$TPIDFILE")"
         else printf '{"kind":"pid","pids":[%s]}' "$roots"; fi ;;
    cgroup) printf '{"kind":"cgroup","cgroup":%s}' "$(jstr "$TCGROUP")" ;;
    *) printf '{"kind":"none"}' ;;
  esac
}

# ---------------------------------------------------------------------------
# Probe (runs on the target machine via `sh -s`; prints key=value lines)
# ---------------------------------------------------------------------------
collector_body() {
  cat <<'COLLECTOR_EOF'
export LC_ALL=C
P="${RESMON_ROOT:-}/proc"
CGR="${RESMON_ROOT:-}/sys/fs/cgroup"
if ! command -v awk >/dev/null 2>&1; then printf 'fatal=awk_missing\nend=1\n'; exit 0; fi
if [ ! -r "$P/stat" ] || [ ! -r "$P/meminfo" ]; then printf 'fatal=proc_unreadable\nend=1\n'; exit 0; fi

printf 'v=2\nhost=%s\nuser=%s\n' "$(uname -n 2>/dev/null || echo unknown)" "$(id -un 2>/dev/null || id -u)"

roots=$RESMON_PIDS
if [ -n "$RESMON_PIDFILE" ]; then
  roots=""
  if [ -r "$RESMON_PIDFILE" ]; then
    roots=$(tr -cs '0-9' ' ' < "$RESMON_PIDFILE" | awk '{ print $1 }')
    [ -n "$roots" ] || printf 'error=pidfile_empty\n'
  else
    printf 'error=pidfile_unreadable\n'
  fi
fi

cg=""
if [ -n "$RESMON_CGROUP" ]; then
  case $RESMON_CGROUP in
    /sys/fs/cgroup*) cg="${RESMON_ROOT:-}$RESMON_CGROUP" ;;
    /*) cg="$CGR$RESMON_CGROUP" ;;
    *) cg="$CGR/$RESMON_CGROUP" ;;
  esac
fi

disk_tokens=""
i=1
while [ "$i" -le "${RESMON_DISK_N:-0}" ]; do
  eval "p=\${RESMON_DISK_$i}"
  sp=$(df -Pk -- "$p" 2>/dev/null | awk 'NR == 2 { u = $3; a = $4; t = u + a; printf "%s %.2f %.3f\n", $1, (t > 0 ? 100 * u / t : 0), a / 1048576 }')
  if [ -z "$sp" ]; then printf 'error=disk_df %s\n' "$i"; i=$((i + 1)); continue; fi
  fs=${sp%% *}; rest=${sp#* }; used=${rest%% *}; avail=${rest#* }
  ino=$(df -Pi -- "$p" 2>/dev/null | awk 'NR == 2 { if ($2 + 0 > 0 && $3 ~ /^[0-9]+$/) printf "%.2f", 100 * $3 / $2; else print "-" }')
  [ -n "$ino" ] || ino="-"
  dn="-"
  case $fs in
    /dev/*) d=$(readlink -f "$fs" 2>/dev/null); [ -n "$d" ] || d=$fs; dn=${d##*/} ;;
  esac
  sd=$(stat -c %d -- "$p" 2>/dev/null); case $sd in ''|*[!0-9]*) sd="-" ;; esac
  disk_tokens="$disk_tokens $i:$used:$avail:$ino:$sd:$dn"
  i=$((i + 1))
done

pids_all=$(cd "$P" 2>/dev/null && echo [0-9]*)
clk=$(getconf CLK_TCK 2>/dev/null); case $clk in ''|*[!0-9]*) clk=100 ;; esac

# cgroup v2 keeps processes only in leaf cgroups: collect the whole subtree.
cgok=0; cgpids=""
if [ -n "$cg" ] && [ -r "$cg/cgroup.procs" ]; then
  cgok=1
  cgpids=$(find "$cg" -name cgroup.procs -exec cat {} + 2>/dev/null | tr -cs '0-9' ' ')
fi

out=$(awk -v P="$P" -v R="${RESMON_ROOT:-}" -v kind="$RESMON_KIND" -v roots="$roots" -v cg="$cg" \
  -v cgok="$cgok" -v cgpids="$cgpids" \
  -v pids_all="$pids_all" -v disks="$disk_tokens" -v W="$RESMON_WINDOW" -v clk="$clk" '
function after_comm(l,   i) {
  for (i = length(l); i > 0; i--) if (substr(l, i, 1) == ")") return substr(l, i + 2)
  return l
}
function first_line(f,   l, v) { v = ""; if ((getline l < f) > 0) v = l; close(f); return v }
function cpu_snap(k,   l, a, n, i, t) {
  NCPU = 0
  while ((getline l < (P "/stat")) > 0) {
    if (l ~ /^cpu /) {
      n = split(l, a, " "); t = 0
      for (i = 2; i <= 9 && i <= n; i++) t += a[i]
      CT[k] = t; CI[k] = a[5] + a[6]; CW[k] = a[6]
    } else if (l ~ /^cpu[0-9]/) NCPU++
  }
  close(P "/stat")
}
function disk_snap(k,   l, a, i, hit) {
  if (ND == 0) return
  while ((getline l < (P "/diskstats")) > 0) {
    split(l, a, " ")
    for (i = 1; i <= ND; i++) {
      hit = 0
      if (DMAJ[i] != "" && a[1] == DMAJ[i] && a[2] == DMIN[i]) hit = 2
      else if (DNAME[i] != "-" && a[3] == DNAME[i]) hit = 1
      if (hit && hit >= DBY[k, i] + 0) {
        DBY[k, i] = hit; DR[k, i] = a[4]; DRS[k, i] = a[6]; DRT[k, i] = a[7]
        DW[k, i] = a[8]; DWS[k, i] = a[10]; DWT[k, i] = a[11]; DIO[k, i] = a[13]
      }
    }
  }
  close(P "/diskstats")
}
function task_snap(k,   i, p, f, l, a, n, j, rc, got) {
  for (i = 1; i <= NT; i++) {
    p = TP[i]; f = P "/" p "/stat"
    if ((getline l < f) > 0) {
      split(after_comm(l), a, " ")
      PT[k, p] = a[12] + a[13]; PS[k, p] = a[20]; PSEEN[k, p] = 1
    }
    close(f)
    f = P "/" p "/io"; got = 0
    while ((getline l < f) > 0) {
      got = 1; split(l, a, " ")
      if (a[1] == "read_bytes:") PR[k, p] = a[2]
      else if (a[1] == "write_bytes:") PW[k, p] = a[2]
    }
    close(f)
    if (got) PIO[k, p] = 1
  }
  if (cg != "") {
    f = cg "/cpu.stat"
    while ((getline l < f) > 0) { split(l, a, " "); if (a[1] == "usage_usec") CGU[k] = a[2] }
    close(f)
    f = cg "/io.stat"; CGR_[k] = 0; CGW_[k] = 0
    while ((rc = (getline l < f)) > 0) {
      n = split(l, a, " ")
      for (j = 2; j <= n; j++) {
        if (a[j] ~ /^rbytes=/) { sub(/^rbytes=/, "", a[j]); CGR_[k] += a[j] }
        else if (a[j] ~ /^wbytes=/) { sub(/^wbytes=/, "", a[j]); CGW_[k] += a[j] }
      }
    }
    close(f)
    CGIO[k] = (rc == 0)
  }
}
BEGIN {
  # memory, load, pressure, oom
  while ((getline l < (P "/meminfo")) > 0) {
    split(l, a, " ")
    if (a[1] == "MemTotal:") mt = a[2]; else if (a[1] == "MemAvailable:") ma = a[2]
    else if (a[1] == "SwapTotal:") st = a[2]; else if (a[1] == "SwapFree:") sf = a[2]
  }
  close(P "/meminfo")
  split(first_line(P "/loadavg"), a, " "); load1 = a[1]
  psim = "-"; psio = "-"
  while ((getline l < (P "/pressure/memory")) > 0) if (l ~ /^full /) { split(l, a, " "); sub(/^avg10=/, "", a[2]); psim = a[2] }
  close(P "/pressure/memory")
  while ((getline l < (P "/pressure/io")) > 0) if (l ~ /^full /) { split(l, a, " "); sub(/^avg10=/, "", a[2]); psio = a[2] }
  close(P "/pressure/io")
  oomk = 0
  while ((getline l < (P "/vmstat")) > 0) { split(l, a, " "); if (a[1] == "oom_kill") oomk = a[2] }
  close(P "/vmstat")

  # every process: owner, parent, memory, threads
  n = split(pids_all, AP, " ")
  for (i = 1; i <= n; i++) {
    p = AP[i]; f = P "/" p "/status"; ok = 0; name = ""; ppid = ""; uid = ""; rss = 0; swp = 0; thr = 1; zomb = 0
    while ((getline l < f) > 0) {
      ok = 1; split(l, a, " ")
      if (a[1] == "Name:") { name = l; sub(/^Name:[ \t]*/, "", name) }
      else if (a[1] == "State:") zomb = (a[2] == "Z" || a[2] == "X")
      else if (a[1] == "PPid:") ppid = a[2]
      else if (a[1] == "Uid:") uid = a[2]
      else if (a[1] == "VmRSS:") rss = a[2] + 0
      else if (a[1] == "VmSwap:") swp = a[2] + 0
      else if (a[1] == "Threads:") thr = a[2] + 0
    }
    close(f)
    if (!ok) continue
    PP[p] = ppid; RSS[p] = rss; SWP[p] = swp; THR[p] = thr; NM[p] = name; ZB[p] = zomb
    if (uid != "") UR[uid] += rss
    KIDS[ppid] = KIDS[ppid] " " p
  }
  while ((getline l < (R "/etc/passwd")) > 0) { split(l, a, ":"); if (!(a[3] in UN)) UN[a[3]] = a[1] }
  close(R "/etc/passwd")

  # task process set
  NT = 0; alive = "-"; aroots = ""
  if (kind == "pid" && roots != "") {
    nr = split(roots, RT, " "); alive = 0
    for (i = 1; i <= nr; i++) {
      p = RT[i]
      if ((p in PP) && !ZB[p] && !(p in IN)) { IN[p] = 1; TP[++NT] = p; alive = 1; aroots = aroots (aroots == "" ? "" : " ") p }
    }
    for (q = 1; q <= NT; q++) {
      m = split(KIDS[TP[q]], K, " ")
      for (j = 1; j <= m; j++) if (!(K[j] in IN) && !ZB[K[j]]) { IN[K[j]] = 1; TP[++NT] = K[j] }
    }
  } else if (kind == "cgroup") {
    alive = 0; ncgp = split(cgpids, CP, " ")
    for (i = 1; i <= ncgp; i++) { p = CP[i]; if ((p in PP) && !ZB[p] && !(p in IN)) { IN[p] = 1; TP[++NT] = p } }
    if (cgok == 1) {
      pop = ""
      while ((getline l < (cg "/cgroup.events")) > 0) { split(l, a, " "); if (a[1] == "populated") pop = a[2] }
      close(cg "/cgroup.events")
      alive = (pop == "1" || (pop == "" && ncgp > 0)) ? 1 : 0
    }
  }

  # disks to sample
  ND = split(disks, DT, " ")
  for (i = 1; i <= ND; i++) {
    split(DT[i], a, ":")
    DIDX[i] = a[1]; DUSED[i] = a[2]; DAV[i] = a[3]; DINO[i] = a[4]; DNAME[i] = a[6]; DMAJ[i] = ""
    if (a[5] != "-") {
      dev = a[5] + 0
      mj = int(dev / 256) % 4096 + (int(dev / 4294967296) - int(dev / 4294967296) % 4096)
      mn = dev % 256 + ((int(dev / 4096) - int(dev / 4096) % 256) % 4294967296)
      if (mj > 0) { DMAJ[i] = mj; DMIN[i] = mn }
    }
  }

  cpu_snap(0); disk_snap(0); task_snap(0)
  system("sleep " W)
  cpu_snap(1); disk_snap(1); task_snap(1)

  ncpu = (NCPU > 0) ? NCPU : 1
  dt = CT[1] - CT[0]
  el = (dt > 0) ? dt / ncpu / clk : W; if (el <= 0) el = W
  busy = (dt > 0) ? 100 * (1 - (CI[1] - CI[0]) / dt) : 0
  iow = (dt > 0) ? 100 * (CW[1] - CW[0]) / dt : 0
  print "ncpu=" ncpu; print "load1=" load1
  printf "cpu_busy_pct=%.2f\niowait_pct=%.2f\n", busy, iow
  printf "mem_total_kb=%d\nmem_avail_kb=%d\nswap_total_kb=%d\nswap_free_kb=%d\n", mt, ma, st, sf
  print "psi_mem_full_avg10=" psim; print "psi_io_full_avg10=" psio; print "oom_kill=" oomk

  for (i = 1; i <= ND; i++) {
    if (DBY[0, i] && DBY[1, i]) {
      ios = (DR[1, i] - DR[0, i]) + (DW[1, i] - DW[0, i])
      util = 100 * (DIO[1, i] - DIO[0, i]) / (el * 1000); if (util > 100) util = 100
      io = sprintf("%.2f %.3f %.3f %.2f %.2f %.3f", util, (DRS[1, i] - DRS[0, i]) * 512 / 1048576 / el,
        (DWS[1, i] - DWS[0, i]) * 512 / 1048576 / el, (DR[1, i] - DR[0, i]) / el, (DW[1, i] - DW[0, i]) / el,
        (ios > 0) ? ((DRT[1, i] - DRT[0, i]) + (DWT[1, i] - DWT[0, i])) / ios : 0)
    } else io = "- - - - - -"
    print "disk=" DIDX[i] " " DUSED[i] " " DAV[i] " " DINO[i] " " DNAME[i] " " io
  }

  print "target_kind=" kind
  if (kind == "none") exit
  print "target_alive=" alive
  print "target_roots=" aroots
  if (alive != 1) exit
  procs = 0; threads = 0; trss = 0; tswp = 0; tcpu = 0; trd = 0; twr = 0; denied = 0
  for (i = 1; i <= NT; i++) {
    p = TP[i]; procs++; threads += THR[p]; trss += RSS[p]; tswp += SWP[p]; PC[p] = 0
    if (PSEEN[0, p] && PSEEN[1, p] && PS[0, p] == PS[1, p]) {
      PC[p] = (dt > 0) ? 100 * (PT[1, p] - PT[0, p]) * ncpu / dt : 0; tcpu += PC[p]
      if (PIO[0, p] && PIO[1, p]) { trd += PR[1, p] - PR[0, p]; twr += PW[1, p] - PW[0, p] }
      else denied++
    }
  }
  tmem = trss; mlim = "-"; toom = "-"
  if (kind == "cgroup") {
    cur = first_line(cg "/memory.current")
    if (cur ~ /^[0-9]+$/) {
      inact = 0
      while ((getline l < (cg "/memory.stat")) > 0) { split(l, a, " "); if (a[1] == "inactive_file") inact = a[2] }
      close(cg "/memory.stat")
      tmem = int((cur - inact) / 1024); if (tmem < 0) tmem = 0
    }
    mx = first_line(cg "/memory.max"); if (mx ~ /^[0-9]+$/) mlim = int(mx / 1024)
    while ((getline l < (cg "/memory.events")) > 0) { split(l, a, " "); if (a[1] == "oom_kill") toom = a[2] }
    close(cg "/memory.events")
    if (CGU[0] != "" && CGU[1] != "") tcpu = 100 * (CGU[1] - CGU[0]) / 1000000 / el
    if (CGIO[0] && CGIO[1]) { trd = CGR_[1] - CGR_[0]; twr = CGW_[1] - CGW_[0]; denied = 0 }
  }
  if (denied > 0) print "error=task_io_unreadable"
  printf "task_procs=%d\ntask_threads=%d\ntask_rss_kb=%d\ntask_swap_kb=%d\ntask_cpu_pct=%.2f\n", procs, threads, tmem, tswp, tcpu
  printf "task_read_mibps=%.3f\ntask_write_mibps=%.3f\n", trd / 1048576 / el, twr / 1048576 / el
  print "task_mem_limit_kb=" mlim; print "task_oom_kill=" toom
  for (r = 1; r <= 5 && r <= NT; r++) {
    best = ""
    for (i = 1; i <= NT; i++) { p = TP[i]; if (!(p in USED) && (best == "" || RSS[p] > RSS[best])) best = p }
    USED[best] = 1
    printf "task_top=%s %d %.2f %s\n", best, RSS[best], PC[best], NM[best]
  }
}
END {
  for (r = 1; r <= 5; r++) {
    best = ""
    for (u in UR) if (!(u in UDONE) && UR[u] > 0 && (best == "" || UR[u] > UR[best])) best = u
    if (best == "") break
    UDONE[best] = 1
    printf "top_user=%d %s\n", UR[best], ((best in UN) ? UN[best] : best)
  }
}' < /dev/null)
printf '%s\n' "$out"
printf '%s\n' "$out" | sed -n 's/^task_top=\([0-9][0-9]*\) .*/\1/p' | while read -r pid; do
  cmd=$(tr '\000' ' ' < "$P/$pid/cmdline" 2>/dev/null | tr -c '[:print:]' ' ' | cut -c1-200)
  [ -n "$cmd" ] && printf 'task_cmd=%s %s\n' "$pid" "$cmd"
done
printf 'time=%s\nend=1\n' "$(date +%s)"
COLLECTOR_EOF
}

build_payload() {
  local i=0
  printf 'RESMON_WINDOW=%s\nRESMON_KIND=%s\n' "$window" "$TKIND"
  printf 'RESMON_PIDS=%s\nRESMON_PIDFILE=%s\nRESMON_CGROUP=%s\n' "$(sq "$TPIDS")" "$(sq "$TPIDFILE")" "$(sq "$TCGROUP")"
  printf 'RESMON_DISK_N=%s\n' "${#DISK_PATHS[@]}"
  while [ "$i" -lt "${#DISK_PATHS[@]}" ]; do
    printf 'RESMON_DISK_%d=%s\n' $((i + 1)) "$(sq "${DISK_PATHS[$i]}")"
    i=$((i + 1))
  done
  [ -n "${RESMON_TEST_ROOT:-}" ] && [ "$MACHINE" = local ] && printf 'RESMON_ROOT=%s\n' "$(sq "$RESMON_TEST_ROOT")"
  collector_body
}

# Run one probe in the background (so stop/note stay responsive); sets rc.
collect_once() {
  local raw=$MDIR/sample.raw err=$MDIR/sample.err lim=$((window + 45)) t0=$SECONDS
  if [ -n "${RESMON_COLLECT_CMD:-}" ]; then
    sh -c "$RESMON_COLLECT_CMD" < "$MDIR/payload.sh" > "$raw" 2> "$err" &
  elif [ "$MACHINE" = local ]; then
    sh -s < "$MDIR/payload.sh" > "$raw" 2> "$err" &
  else
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 \
      "$MACHINE" 'sh -s' < "$MDIR/payload.sh" > "$raw" 2> "$err" &
  fi
  cpid=$!
  while kill -0 "$cpid" 2>/dev/null; do
    if [ $((SECONDS - t0)) -ge "$lim" ]; then
      kill "$cpid" 2>/dev/null; echo "probe timed out after ${lim}s" >> "$err"
    fi
    sleep 1
  done
  wait "$cpid"; rc=$?
  cpid=""
  if [ "$rc" -eq 0 ] && ! grep -q '^end=1$' "$raw"; then rc=97; echo "incomplete probe output" >> "$err"; fi
}

# ---------------------------------------------------------------------------
# Evaluation (controller side): sample + previous state -> events, sample JSON, new state
# ---------------------------------------------------------------------------
EVAL_AWK='
function ev(type, frag) { printf "EVENT\t%s\t%s\n", type, frag }
function nz(x) { return (x == "" || x == "-") ? "" : x + 0 }
function chk(key, metric, scope, path, obs, lim, unit, sus, msg) {
  if (obs == "" || obs == "-") return
  KEYS[++NK] = key; MET[key] = metric; SCO[key] = scope; PTH[key] = path
  OBS[key] = obs + 0; LIM[key] = lim + 0; UNIT[key] = unit; MSG[key] = msg
  if (lim + 0 > 0 && obs + 0 >= lim + 0) { BR[key] = 1; SUS[key] = sus }
}
function hint(m) {
  if (m == "task_rss_gib" || m == "task_rss_pct" || m == "task_mem_limit_pct")
    return "Task memory over limit: shrink batch size / workers / caches, or restart the largest process in context.task_top."
  if (m == "task_rss_growth_gib_per_min") return "Task memory is climbing fast: likely a leak or unbounded cache in context.task_top[0]."
  if (m == "task_oom_new") return "The kernel OOM-killed processes inside the task cgroup."
  if (m == "task_cpu_pct") return "Task CPU over limit: lower thread/worker counts (OMP_NUM_THREADS, num_workers, -j)."
  if (m == "task_procs" || m == "task_threads") return "Task is spawning too many processes/threads: check for runaway forks or pools."
  if (m ~ /^task_(read|write)_mibps$/) return "Task disk I/O over limit: reduce logging, checkpoint frequency or data loading rate."
  if (m ~ /^(mem_used_pct|swap_used_pct|psi_mem_full_avg10|oom_kill_new)$/)
    return "Machine memory pressure. Compare task.rss_pct with context.top_users to see whether the task or another user is responsible."
  if (m ~ /^(cpu_busy_pct|load_per_cpu|iowait_pct)$/) return "Machine CPU saturated. Compare task.cpu_pct with the machine total before throttling the task."
  if (m ~ /^disk_(used|inodes)_pct$/) return "Disk filling up: delete or move outputs/checkpoints, or redirect writes to another path."
  if (m ~ /^(disk_util_pct|disk_await_ms|disk_read_mibps|disk_write_mibps|psi_io_full_avg10)$/)
    return "Disk I/O saturated: reduce write/read rate (logging, checkpoints, data loading) or move I/O to another device."
  return ""
}
function errfrag(e,   code, det, msg, o) {
  code = e; det = ""
  if (index(e, " ")) { code = substr(e, 1, index(e, " ") - 1); det = substr(e, index(e, " ") + 1) }
  if (code == "disk_df") msg = "df failed for " DP[det] " (path missing or not mounted?)"
  else if (code == "pidfile_unreadable") msg = "cannot read the target pid file"
  else if (code == "pidfile_empty") msg = "target pid file holds no pid"
  else if (code == "task_io_unreadable") msg = "cannot read /proc/<pid>/io for some task processes; task I/O is partial"
  else if (code == "awk_missing") msg = "awk not found on the target machine"
  else if (code == "proc_unreadable") msg = "/proc is not readable on the target (not Linux?)"
  else if (code == "incomplete_sample") msg = "probe output is missing required fields"
  else msg = code
  o = "\"code\":" js(code) ",\"message\":" js(msg)
  if (code == "disk_df") o = o ",\"path\":" js(DP[det])
  else if (det != "") o = o ",\"detail\":" js(det)
  return o
}
function save_state(   k, e) {
  printf "" > stateout
  for (k in NEWP) print k " " NEWP[k] > stateout
  for (k in NST) print "streak " k " " NST[k] > stateout
  for (k in NACT) print "active " k " 1" > stateout
  for (e in ERRS) print "err " e > stateout
  close(stateout)
}
function roots_json(s,   a, n, i, o) {
  n = split(s, a, " "); o = ""
  for (i = 1; i <= n; i++) o = o (i > 1 ? "," : "") a[i]
  return "[" o "]"
}
function head() { return "\"at\":" js(now_iso) ",\"monitor_id\":" js(mid) ",\"task_id\":" js(tid) ",\"machine\":" js(mach) }
BEGIN {
  GIB = 1048576
  mid = ENVIRON["R_MID"]; tid = ENVIRON["R_TASK"]; mach = ENVIRON["R_MACHINE"]
  while ((getline l < limits) > 0) {
    split(l, a, " ")
    if (a[1] == "disk_path") DP[a[2]] = substr(l, length(a[1]) + length(a[2]) + 3)
    else if (a[1] == "disk_limit") DLIM[a[2]] = a[3]
    else L[a[1]] = a[2]
  }
  close(limits)
  sustain = L["sustain"] + 0; if (oneshot || sustain < 1) sustain = 1
  realert = L["realert"] + 0; if (realert < 1) realert = 1
  while ((getline l < statein) > 0) {
    split(l, a, " ")
    if (a[1] == "streak") ST[a[2]] = a[3] + 0
    else if (a[1] == "active") ACT[a[2]] = 1
    else if (a[1] == "err") OLDERR[substr(l, 5)] = 1
    else PREV[a[1]] = substr(l, length(a[1]) + 2)
  }
  close(statein)
  while ((getline l < sample) > 0) {
    k = l; sub(/=.*/, "", k); v = substr(l, length(k) + 2)
    if (k == "disk") DL[++NDL] = v
    else if (k == "task_top") TL[++NTL] = v
    else if (k == "task_cmd") { split(v, a, " "); CMD[a[1]] = substr(v, length(a[1]) + 2) }
    else if (k == "top_user") UL[++NUL] = v
    else if (k == "error") ERRS[v] = 1
    else if (k == "fatal") FATAL = v
    else S[k] = v
  }
  close(sample)

  if (reset != "") { split("", PREV); split("", ST); ev("baseline_reset", head() ",\"reason\":" js(reset)) }
  if (FATAL == "" && (!("cpu_busy_pct" in S) || !("mem_total_kb" in S) || !("time" in S))) FATAL = "incomplete_sample"
  if (FATAL != "") ERRS[FATAL] = 1
  nerr = 0
  # warnings mean partial data the agent cannot fix: recorded, but they do not wake `wait`
  for (e in ERRS) {
    w = (e == "task_io_unreadable")
    if (!w) nerr++
    if (!(e in OLDERR)) ev(w ? "collect_warning" : "collect_error", head() "," errfrag(e))
  }
  for (e in OLDERR) if (!(e in ERRS)) ev("collect_recovered", head() "," errfrag(e))
  if (FATAL != "") {
    for (k in PREV) NEWP[k] = PREV[k]; for (k in ST) NST[k] = ST[k]; for (k in ACT) NACT[k] = 1
    save_state(); printf "FLAGS\tfired=0 errors=%d fatal=1 target_exit=0\n", nerr; exit
  }

  now_t = S["time"] + 0
  ncpu = S["ncpu"] + 0; if (ncpu < 1) ncpu = 1
  mt = S["mem_total_kb"] + 0; ma = S["mem_avail_kb"] + 0; stt = S["swap_total_kb"] + 0; sf = S["swap_free_kb"] + 0
  mem_pct = (mt > 0) ? 100 * (1 - ma / mt) : ""
  swap_pct = (stt > 0) ? 100 * (1 - sf / stt) : ""
  lpc = S["load1"] / ncpu
  psim = nz(S["psi_mem_full_avg10"]); psio = nz(S["psi_io_full_avg10"])
  oom = S["oom_kill"] + 0
  oom_new = ("oom" in PREV && oom >= PREV["oom"] + 0) ? oom - PREV["oom"] : ""
  NEWP["time"] = now_t; NEWP["oom"] = oom

  chk("cpu_busy_pct", "cpu_busy_pct", "machine", "", S["cpu_busy_pct"], L["cpu_busy_pct"], "%", 1,
      sprintf("machine CPU %.0f%% busy (iowait %.0f%%) on %d CPUs", S["cpu_busy_pct"], S["iowait_pct"], ncpu))
  chk("load_per_cpu", "load_per_cpu", "machine", "", lpc, L["load_per_cpu"], "load/cpu", 1,
      sprintf("load1 %.1f on %d CPUs", S["load1"], ncpu))
  chk("iowait_pct", "iowait_pct", "machine", "", S["iowait_pct"], L["iowait_pct"], "%", 1, sprintf("CPU iowait %.0f%%", S["iowait_pct"]))
  chk("mem_used_pct", "mem_used_pct", "machine", "", mem_pct, L["mem_used_pct"], "%", 0,
      sprintf("machine memory %.0f%% used (%.1f of %.1f GiB)", mem_pct, (mt - ma) / GIB, mt / GIB))
  chk("swap_used_pct", "swap_used_pct", "machine", "", swap_pct, L["swap_used_pct"], "%", 0,
      sprintf("swap %.0f%% used (%.1f of %.1f GiB)", swap_pct, (stt - sf) / GIB, stt / GIB))
  chk("psi_mem_full_avg10", "psi_mem_full_avg10", "machine", "", psim, L["psi_mem_full_avg10"], "%", 0,
      "memory pressure (PSI full avg10) " psim "%")
  chk("psi_io_full_avg10", "psi_io_full_avg10", "machine", "", psio, L["psi_io_full_avg10"], "%", 1,
      "I/O pressure (PSI full avg10) " psio "%")
  chk("oom_kill_new", "oom_kill_new", "machine", "", oom_new, L["oom_kill_new"], "kills", 0,
      oom_new " new OOM kill(s) on the machine since the previous sample")

  dj = ""; dsum = ""
  for (i = 1; i <= NDL; i++) {
    split(DL[i], a, " ")
    x = a[1]; path = DP[x]
    lim = (x in DLIM) ? DLIM[x] : L["disk_used_pct"]
    chk("disk_used_pct@" x, "disk_used_pct", "disk", path, a[2], lim, "%", 0,
        sprintf("%s %.0f%% used, %.1f GiB free", path, a[2], a[3]))
    chk("disk_inodes_pct@" x, "disk_inodes_pct", "disk", path, a[4], L["disk_inodes_pct"], "%", 0,
        sprintf("%s inodes %.0f%% used", path, a[4]))
    chk("disk_util_pct@" x, "disk_util_pct", "disk", path, a[6], L["disk_util_pct"], "%", 1,
        sprintf("%s (%s) %.0f%% busy", path, a[5], a[6]))
    chk("disk_await_ms@" x, "disk_await_ms", "disk", path, a[11], L["disk_await_ms"], "ms", 1,
        sprintf("%s (%s) average I/O wait %.1f ms", path, a[5], a[11]))
    chk("disk_read_mibps@" x, "disk_read_mibps", "disk", path, a[7], L["disk_read_mibps"], "MiB/s", 1,
        sprintf("%s (%s) reading %.1f MiB/s", path, a[5], a[7]))
    chk("disk_write_mibps@" x, "disk_write_mibps", "disk", path, a[8], L["disk_write_mibps"], "MiB/s", 1,
        sprintf("%s (%s) writing %.1f MiB/s", path, a[5], a[8]))
    dj = dj (dj == "" ? "" : ",") "{\"path\":" js(path) ",\"device\":" (a[5] == "-" ? "null" : js(a[5])) \
      ",\"used_pct\":" num(a[2]) ",\"avail_gib\":" num(a[3]) ",\"inodes_pct\":" num(a[4]) \
      ",\"util_pct\":" num(a[6]) ",\"read_mibps\":" num(a[7]) ",\"write_mibps\":" num(a[8]) \
      ",\"read_iops\":" num(a[9]) ",\"write_iops\":" num(a[10]) ",\"await_ms\":" num(a[11]) "}"
    dsum = dsum " " path ":" sprintf("%.0f%%", a[2]) (a[6] == "-" ? "" : sprintf(" util %.0f%%", a[6]))
  }
  for (x in DP) {  # paths whose df failed still need a row
    found = 0; for (i = 1; i <= NDL; i++) { split(DL[i], a, " "); if (a[1] == x) found = 1 }
    if (!found) dj = dj (dj == "" ? "" : ",") "{\"path\":" js(DP[x]) ",\"error\":\"df_failed\"}"
  }

  kind = S["target_kind"]; texit = 0; tj = "null"; tsum = ""
  if (kind == "pid" || kind == "cgroup") {
    alive = S["target_alive"]; roots = S["target_roots"]
    if (alive == "0") {
      texit = 1
      ev("target_exit", head() ",\"target\":{\"kind\":" js(kind) ",\"last_roots\":" roots_json(PREV["roots"]) \
        "},\"last_rss_gib\":" num(PREV["task_rss_kb"] / GIB) ",\"message\":\"target process/cgroup is gone\"")
      tj = "{\"kind\":" js(kind) ",\"alive\":false}"
      tsum = " | task exited"
    } else if (alive == "1") {
      if (("roots" in PREV) && PREV["roots"] != roots && reset == "") {
        ev("baseline_reset", head() ",\"reason\":\"target_changed\",\"from\":" roots_json(PREV["roots"]) ",\"to\":" roots_json(roots))
        delete PREV["time"]; delete PREV["task_rss_kb"]; delete PREV["task_oom"]
      }
      NEWP["roots"] = roots
      rkb = S["task_rss_kb"] + 0; rg = rkb / GIB; rp = (mt > 0) ? 100 * rkb / mt : ""
      NEWP["task_rss_kb"] = rkb
      growth = ""
      if (("time" in PREV) && ("task_rss_kb" in PREV)) {
        mins = (now_t - PREV["time"]) / 60
        if (mins >= 0.05) growth = ((rkb - PREV["task_rss_kb"]) / GIB) / mins
      }
      mlk = nz(S["task_mem_limit_kb"]); mlp = (mlk != "" && mlk > 0) ? 100 * rkb / mlk : ""
      toom = nz(S["task_oom_kill"]); toom_new = ""
      if (toom != "") { NEWP["task_oom"] = toom; if (("task_oom" in PREV) && toom >= PREV["task_oom"] + 0) toom_new = toom - PREV["task_oom"] }
      chk("task_rss_gib", "task_rss_gib", "task", "", rg, L["task_rss_gib"], "GiB", 0,
          sprintf("task memory %.1f GiB in %d processes", rg, S["task_procs"]))
      chk("task_rss_pct", "task_rss_pct", "task", "", rp, L["task_rss_pct"], "%", 0, sprintf("task holds %.0f%% of machine RAM", rp))
      chk("task_mem_limit_pct", "task_mem_limit_pct", "task", "", mlp, L["task_mem_limit_pct"], "%", 0,
          sprintf("task at %.0f%% of its cgroup memory.max (%.1f GiB)", mlp, mlk / GIB))
      chk("task_rss_growth_gib_per_min", "task_rss_growth_gib_per_min", "task", "", growth, L["task_rss_growth_gib_per_min"], "GiB/min", 0,
          sprintf("task memory growing %.2f GiB/min (now %.1f GiB)", growth, rg))
      chk("task_cpu_pct", "task_cpu_pct", "task", "", S["task_cpu_pct"], L["task_cpu_pct"], "% of one core", 1,
          sprintf("task using %.0f%% CPU (%.1f cores)", S["task_cpu_pct"], S["task_cpu_pct"] / 100))
      chk("task_procs", "task_procs", "task", "", S["task_procs"], L["task_procs"], "procs", 0, S["task_procs"] " task processes")
      chk("task_threads", "task_threads", "task", "", S["task_threads"], L["task_threads"], "threads", 0, S["task_threads"] " task threads")
      chk("task_read_mibps", "task_read_mibps", "task", "", S["task_read_mibps"], L["task_read_mibps"], "MiB/s", 1,
          sprintf("task reading %.1f MiB/s from disk", S["task_read_mibps"]))
      chk("task_write_mibps", "task_write_mibps", "task", "", S["task_write_mibps"], L["task_write_mibps"], "MiB/s", 1,
          sprintf("task writing %.1f MiB/s to disk", S["task_write_mibps"]))
      chk("task_oom_new", "task_oom_new", "task", "", toom_new, L["task_oom_new"], "kills", 0, toom_new " new OOM kill(s) inside the task cgroup")
      top = ""
      for (i = 1; i <= NTL; i++) {
        n = split(TL[i], a, " "); nm = ""
        for (j = 4; j <= n; j++) nm = nm (j > 4 ? " " : "") a[j]
        top = top (i > 1 ? "," : "") "{\"pid\":" a[1] ",\"rss_gib\":" num(a[2] / GIB) ",\"cpu_pct\":" num(a[3]) \
          ",\"name\":" js(nm) ",\"cmd\":" ((a[1] in CMD) ? js(CMD[a[1]]) : "null") "}"
      }
      tj = "{\"kind\":" js(kind) ",\"alive\":true,\"roots\":" roots_json(roots) ",\"procs\":" num(S["task_procs"]) \
        ",\"threads\":" num(S["task_threads"]) ",\"rss_gib\":" num(rg) ",\"rss_pct\":" num(rp) \
        ",\"swap_gib\":" num(S["task_swap_kb"] / GIB) ",\"cpu_pct\":" num(S["task_cpu_pct"]) \
        ",\"read_mibps\":" num(S["task_read_mibps"]) ",\"write_mibps\":" num(S["task_write_mibps"]) \
        ",\"mem_limit_gib\":" (mlk == "" ? "null" : num(mlk / GIB)) ",\"mem_limit_pct\":" num(mlp) \
        ",\"rss_growth_gib_per_min\":" num(growth) ",\"top\":[" top "]}"
      tsum = sprintf(" | task %d procs %.1fGiB cpu %.0f%%", S["task_procs"], rg, S["task_cpu_pct"])
    } else {
      tj = "{\"kind\":" js(kind) ",\"alive\":null}"
      tsum = " | task unknown"
      if ("roots" in PREV) NEWP["roots"] = PREV["roots"]
    }
  }

  uj = ""
  for (i = 1; i <= NUL; i++) {
    split(UL[i], a, " ")
    uj = uj (i > 1 ? "," : "") "{\"user\":" js(a[2]) ",\"rss_gib\":" num(a[1] / GIB) "}"
  }
  summary = sprintf("cpu %.0f%% load %.2f/cpu mem %.0f%% swap %s psi %s |%s%s", S["cpu_busy_pct"], lpc, mem_pct,
    (swap_pct == "" ? "-" : sprintf("%.0f%%", swap_pct)), (psim == "" ? "-" : psim), dsum, tsum)
  ctx = "{\"summary\":" js(summary) ",\"task\":" tj ",\"top_users\":[" uj "]}"

  fired = 0; aj = ""
  for (i = 1; i <= NK; i++) {
    k = KEYS[i]
    if (k in BR) {
      n = ST[k] + 1; NST[k] = n
      need = SUS[k] ? sustain : 1
      if (n >= need) {
        NACT[k] = 1; r = n - need
        aj = aj (aj == "" ? "" : ",") "{\"metric\":" js(MET[k]) (PTH[k] != "" ? ",\"path\":" js(PTH[k]) : "") \
          ",\"observed\":" num(OBS[k]) ",\"limit\":" num(LIM[k]) "}"
        if (r % realert == 0) {
          fired++
          ev("threshold", head() ",\"metric\":" js(MET[k]) ",\"scope\":" js(SCO[k]) (PTH[k] != "" ? ",\"path\":" js(PTH[k]) : "") \
            ",\"observed\":" num(OBS[k]) ",\"limit\":" num(LIM[k]) ",\"unit\":" js(UNIT[k]) \
            ",\"sustained_samples\":" n ",\"repeat\":" int(r / realert) ",\"message\":" js(MSG[k]) \
            ",\"hint\":" js(hint(MET[k])) ",\"context\":" ctx)
        }
      }
    } else if (k in ACT) {
      ev("recovered", head() ",\"metric\":" js(MET[k]) ",\"scope\":" js(SCO[k]) (PTH[k] != "" ? ",\"path\":" js(PTH[k]) : "") \
        ",\"observed\":" num(OBS[k]) ",\"limit\":" num(LIM[k]) ",\"message\":" js(MSG[k]))
    }
    EVD[k] = 1
  }
  for (k in ST) if (!(k in EVD)) NST[k] = ST[k]
  for (k in ACT) if (!(k in EVD)) NACT[k] = 1

  ej = ""; for (e in ERRS) ej = ej (ej == "" ? "" : ",") js(e)
  printf "SAMPLE\t{\"type\":\"sample\",%s,\"host\":%s,\"system\":{\"ncpu\":%d,\"load1\":%s,\"load_per_cpu\":%s,\"cpu_busy_pct\":%s,\"iowait_pct\":%s,\"mem_total_gib\":%s,\"mem_used_gib\":%s,\"mem_used_pct\":%s,\"swap_used_pct\":%s,\"psi_mem_full_avg10\":%s,\"psi_io_full_avg10\":%s,\"oom_kill_new\":%s,\"user\":%s},\"disks\":[%s],\"task\":%s,\"top_users\":[%s],\"active\":[%s],\"errors\":[%s],\"summary\":%s}\n", \
    head(), js(S["host"]), ncpu, num(S["load1"]), num(lpc), num(S["cpu_busy_pct"]), num(S["iowait_pct"]), num(mt / GIB), \
    num((mt - ma) / GIB), num(mem_pct), num(swap_pct), num(psim), num(psio), num(oom_new), js(S["user"]), dj, tj, uj, aj, ej, js(summary)
  printf "STATE\t\"active\":[%s],\"errors\":[%s]\n", aj, ej
  save_state()
  printf "FLAGS\tfired=%d errors=%d fatal=0 target_exit=%d\n", fired, nerr, texit
}'

# Sets: E_FIRED E_ERRORS E_FATAL E_TEXIT E_SAMPLE E_STATE and emits events via emit().
run_eval() { # $1 oneshot(0/1)  $2 reset reason
  local out line rest type frag
  out=$(R_MID="$MONITOR_ID" R_TASK="$TASK_ID" R_MACHINE="$MACHINE" awk -v sample="$MDIR/sample.raw" \
    -v statein="$MDIR/eval.state" -v stateout="$MDIR/eval.state.new" -v limits="$MDIR/limits" \
    -v now_iso="$(now_iso)" -v oneshot="$1" -v reset="$2" "$AWK_LIB$EVAL_AWK")
  [ -f "$MDIR/eval.state.new" ] && mv -f "$MDIR/eval.state.new" "$MDIR/eval.state"
  E_FIRED=0; E_ERRORS=0; E_FATAL=0; E_TEXIT=0; E_SAMPLE=""; E_STATE=""
  while IFS= read -r line; do
    case $line in
      EVENT$'\t'*)
        rest=${line#EVENT$'\t'}; type=${rest%%$'\t'*}; frag=${rest#*$'\t'}
        emit_raw "$type" "$frag" ;;
      SAMPLE$'\t'*) E_SAMPLE=${line#SAMPLE$'\t'} ;;
      STATE$'\t'*) E_STATE=${line#STATE$'\t'} ;;
      FLAGS$'\t'*)
        rest=${line#FLAGS$'\t'}
        for kv in $rest; do
          case $kv in
            fired=*) E_FIRED=${kv#fired=} ;; errors=*) E_ERRORS=${kv#errors=} ;;
            fatal=*) E_FATAL=${kv#fatal=} ;; target_exit=*) E_TEXIT=${kv#target_exit=} ;;
          esac
        done ;;
    esac
  done <<EOF
$out
EOF
}

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------
last_seq() { # $1 events file
  [ -f "$1" ] || { echo 0; return; }
  awk 'match($0, /^\{"seq":[0-9]+/) { s = substr($0, 8, RLENGTH - 7) + 0; if (s > m) m = s } END { print m + 0 }' "$1"
}

# emit_raw TYPE FRAG — FRAG already holds at/monitor_id/task_id/machine (from awk)
emit_raw() {
  SEQ=$((SEQ + 1))
  local line="{\"seq\":$SEQ,\"type\":\"$1\",$2}"
  [ -n "$EVENTS" ] && printf '%s\n' "$line" >> "$EVENTS"
  [ "$ECHO_EVENTS" = 1 ] && printf '%s\n' "$line"
  [ "${BUFFER_EVENTS:-0}" = 1 ] && EVBUF="$EVBUF$line"$'\n'
  return 0
}

# emit TYPE [FRAG] — adds the common header in shell
emit() {
  emit_raw "$1" "\"at\":\"$(now_iso)\",\"monitor_id\":$J_ID,\"task_id\":$J_TASK,\"machine\":$J_MACHINE${2:+,$2}"
}

write_state_json() { # $1 status
  [ -n "$MDIR" ] || return 0
  local tmp="$MDIR/state.json.tmp"
  printf '{"monitor_id":%s,"task_id":%s,"machine":%s,"status":"%s","pid":%s,"updated_at":"%s","last_seq":%s,"consecutive_failures":%s,%s,"last_sample":%s}\n' \
    "$J_ID" "$J_TASK" "$J_MACHINE" "$1" "$$" "$(now_iso)" "$SEQ" "${fails:-0}" "${E_STATE:-\"active\":[],\"errors\":[]}" \
    "${E_SAMPLE:-null}" > "$tmp" && mv -f "$tmp" "$MDIR/state.json"
}

# ---------------------------------------------------------------------------
# Monitor loop (used by `run` and the detached `start` daemon)
# ---------------------------------------------------------------------------
FINISHED=0
cpid=""

finish() { # $1 reason
  [ "$FINISHED" = 1 ] && exit 0
  FINISHED=1
  [ -n "$cpid" ] && kill "$cpid" 2>/dev/null
  emit stopped "\"reason\":\"$1\""
  write_state_json stopped
  rm -f "$MDIR/pid"
  exit 0
}

on_exit() {
  if [ "$FINISHED" != 1 ]; then
    FINISHED=1
    [ -n "$cpid" ] && kill "$cpid" 2>/dev/null
    emit stopped "\"reason\":\"crashed\""
    write_state_json stopped
    rm -f "$MDIR/pid"
  fi
}

process_control() {
  local f line reset newpid msg frag old
  for f in "$MDIR"/ctl/*.ctl; do
    [ -f "$f" ] || continue
    reset=0; newpid=""; msg=""
    while IFS= read -r line; do
      case $line in
        reset=*) reset=${line#reset=} ;;
        pid=*) newpid=${line#pid=} ;;
        msg=*) msg=${line#msg=} ;;
      esac
    done < "$f"
    rm -f "$f"
    frag="\"message\":$(jstr "$msg")"
    if [ -n "$newpid" ]; then
      if [ -z "$TPIDFILE" ] && [ "$TKIND" != cgroup ]; then
        old=$TPIDS; TKIND=pid; TPIDS=$(printf '%s' "$newpid" | tr ',' ' ')
        build_payload > "$MDIR/payload.sh"
        frag="$frag,\"retarget\":{\"from\":$(jstr "$old"),\"to\":$(jstr "$TPIDS")}"
        reset=1; pending_reset=retarget
      else
        frag="$frag,\"retarget_error\":\"retarget only works for --pid targets\""
      fi
    fi
    if [ "$reset" = 1 ]; then
      frag="$frag,\"reset_baseline\":true"
      pending_reset=${pending_reset:-intervention}
    else
      frag="$frag,\"reset_baseline\":false"
    fi
    emit intervention "$frag"
  done
}

monitor_loop() {
  SEQ=$(last_seq "$EVENTS")
  J_ID=$(jstr "$MONITOR_ID"); J_TASK=$(jstr "$TASK_ID"); J_MACHINE=$(jstr "$MACHINE")
  mkdir -p "$MDIR/ctl"
  write_limits "$MDIR/limits"
  build_payload > "$MDIR/payload.sh"
  : > "$MDIR/eval.state"
  echo "$$" > "$MDIR/pid"
  trap 'finish requested' TERM INT HUP
  trap on_exit EXIT
  emit started "\"pid\":$$,\"target\":$(target_json),\"interval\":$interval,\"window\":$window,\"ttl\":$ttl,\"sustain\":$sustain,\"realert\":$realert,\"stop_on_alert\":$([ "$stop_on_alert" = 1 ] && echo true || echo false),\"limits\":$(limits_json),\"disks\":$(disks_json)"
  write_state_json running
  fails=0; down=0; pending_reset=""
  local began=$SECONDS t0 err
  while :; do
    t0=$SECONDS
    process_control
    collect_once
    if [ "$rc" -ne 0 ]; then
      fails=$((fails + 1))
      err=$(tail -n 3 "$MDIR/sample.err" 2>/dev/null | tr '\r\n' '  ')
      [ -n "$err" ] || err="probe exited with status $rc"
      emit sample_failed "\"attempt\":$fails,\"exit_code\":$rc,\"error\":$(jstr "$err")"
      if [ "$fails" -eq "$unreachable" ]; then
        down=1
        emit unreachable "\"failures\":$fails,\"error\":$(jstr "$err"),\"message\":\"$MACHINE unreachable after $fails consecutive failed samples\""
        [ "$stop_on_alert" = 1 ] && finish unreachable
      fi
      write_state_json running
    else
      if [ "$down" = 1 ]; then
        emit reachable "\"after_failures\":$fails"
        pending_reset=${pending_reset:-collection_gap}
        down=0
      fi
      fails=0
      run_eval 0 "$pending_reset"
      pending_reset=""
      [ -n "$E_SAMPLE" ] && printf '%s\n' "$E_SAMPLE" >> "$MDIR/samples.jsonl"
      write_state_json running
      [ "$E_TEXIT" = 1 ] && finish target_exit
      [ "$E_FIRED" -gt 0 ] && [ "$stop_on_alert" = 1 ] && finish alert
    fi
    [ "$ttl" -gt 0 ] && [ $((SECONDS - began)) -ge "$ttl" ] && finish ttl
    while [ $((SECONDS - t0)) -lt "$interval" ]; do
      sleep 1
      process_control
      [ "$ttl" -gt 0 ] && [ $((SECONDS - began)) -ge "$ttl" ] && finish ttl
    done
  done
}

new_monitor_dir() {
  local base id
  base=$(printf '%s' "$TASK_ID" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-40)
  id="$base-$(date +%Y%m%d-%H%M%S)-$$"
  umask 077
  mkdir -p "$RESMON_HOME" || die "cannot create $RESMON_HOME"
  mkdir "$RESMON_HOME/$id" || die "cannot create monitor dir"
  mkdir "$RESMON_HOME/$id/ctl"
  {
    printf 'task_id=%s\nmachine=%s\ncreated_at=%s\n' "$TASK_ID" "$MACHINE" "$(now_iso)"
  } > "$RESMON_HOME/$id/meta"
  echo "$RESMON_HOME/$id"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_start() {
  parse_monitor_args start "$@"
  local dir id pid i launcher
  dir=$(new_monitor_dir) || exit 1
  id=$(basename "$dir")
  if command -v setsid >/dev/null 2>&1; then launcher="setsid"
  elif command -v perl >/dev/null 2>&1; then launcher="perl"
  else launcher=""; fi
  case $launcher in
    setsid) nohup setsid bash "$SELF" _daemon "$dir" "$@" >> "$dir/monitor.log" 2>&1 < /dev/null & ;;
    perl) nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!"' bash "$SELF" _daemon "$dir" "$@" >> "$dir/monitor.log" 2>&1 < /dev/null & ;;
    *) nohup bash "$SELF" _daemon "$dir" "$@" >> "$dir/monitor.log" 2>&1 < /dev/null & ;;
  esac
  i=0
  while [ "$i" -lt 50 ]; do
    if [ -f "$dir/pid" ] && grep -q '"type":"started"' "$dir/events.jsonl" 2>/dev/null; then break; fi
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  pid=$(cat "$dir/pid" 2>/dev/null)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    echo "$PROG: monitor failed to start; log:" >&2
    tail -n 20 "$dir/monitor.log" >&2
    exit 1
  fi
  J_ID=$(jstr "$id")
  printf '{"monitor_id":%s,"pid":%s,"task_id":%s,"machine":%s,"target":%s,"interval":%s,"dir":%s,"event_file":%s,"state_file":%s,"samples_file":%s,"log_file":%s,"wait_cmd":%s,"stop_cmd":%s}\n' \
    "$J_ID" "$pid" "$(jstr "$TASK_ID")" "$(jstr "$MACHINE")" "$(target_json)" "$interval" "$(jstr "$dir")" \
    "$(jstr "$dir/events.jsonl")" "$(jstr "$dir/state.json")" "$(jstr "$dir/samples.jsonl")" "$(jstr "$dir/monitor.log")" \
    "$(jstr "$SELF wait $id")" "$(jstr "$SELF stop $id")"
}

cmd_daemon() {
  MDIR=$1; shift
  parse_monitor_args start "$@"
  MONITOR_ID=$(basename "$MDIR"); EVENTS="$MDIR/events.jsonl"; ECHO_EVENTS=0
  monitor_loop
}

cmd_run() {
  parse_monitor_args run "$@"
  MDIR=$(new_monitor_dir) || exit 1
  MONITOR_ID=$(basename "$MDIR"); EVENTS="$MDIR/events.jsonl"; ECHO_EVENTS=1
  monitor_loop
}

cmd_check() {
  parse_monitor_args check "$@"
  MDIR=$(mktemp -d "${TMPDIR:-/tmp}/resmon.XXXXXX") || die "mktemp failed"
  trap 'rm -rf "$MDIR"' EXIT
  MONITOR_ID=check; EVENTS=""; ECHO_EVENTS=1; SEQ=0
  J_ID=$(jstr "$MONITOR_ID"); J_TASK=$(jstr "$TASK_ID"); J_MACHINE=$(jstr "$MACHINE")
  write_limits "$MDIR/limits"; build_payload > "$MDIR/payload.sh"; : > "$MDIR/eval.state"
  collect_once
  if [ "$rc" -ne 0 ]; then
    local err; err=$(tail -n 3 "$MDIR/sample.err" 2>/dev/null | tr '\r\n' '  ')
    emit sample_failed "\"attempt\":1,\"exit_code\":$rc,\"error\":$(jstr "${err:-probe exited with status $rc}")"
    exit 3
  fi
  ECHO_EVENTS=0; BUFFER_EVENTS=1; EVBUF=""
  run_eval 1 ""
  [ -n "$E_SAMPLE" ] && printf '%s\n' "$E_SAMPLE"
  printf '%s' "$EVBUF"
  [ "$E_FIRED" -gt 0 ] && exit 2
  [ "$E_FATAL" = 1 ] || [ "$E_ERRORS" -gt 0 ] && exit 3
  [ "$E_TEXIT" = 1 ] && exit 4
  exit 0
}

# Resolve a monitor id / task id / dir into $MDIR.
resolve_monitor() {
  local arg=$1 base cand d
  [ -n "$arg" ] || die "missing <monitor>"
  if [ -d "$RESMON_HOME/$arg" ]; then MDIR="$RESMON_HOME/$arg"
  elif [ -f "$arg/events.jsonl" ]; then MDIR=$(cd "$arg" && pwd)
  else
    base=$(printf '%s' "$arg" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-40)
    cand=""
    for d in "$RESMON_HOME/$base"-*; do [ -d "$d" ] && cand=$d; done
    [ -n "$cand" ] || die "no monitor matching '$arg' in $RESMON_HOME"
    MDIR=$cand
  fi
  MONITOR_ID=$(basename "$MDIR"); EVENTS="$MDIR/events.jsonl"
}

monitor_alive() {
  local pid
  pid=$(cat "$MDIR/pid" 2>/dev/null) || return 1
  is_uint "$pid" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q "$(basename "$SELF")"
}

meta_get() { sed -n "s/^$1=//p" "$MDIR/meta" 2>/dev/null | head -n 1; }

# Append an event from outside the daemon (only when the daemon is gone).
emit_offline() {
  ECHO_EVENTS=${ECHO_EVENTS:-0}
  SEQ=$(last_seq "$EVENTS")
  J_ID=$(jstr "$MONITOR_ID"); J_TASK=$(jstr "$(meta_get task_id)"); J_MACHINE=$(jstr "$(meta_get machine)")
  emit "$@"
}

ACTIONABLE="threshold,collect_error,unreachable,target_exit,stopped,monitor_died"

cmd_wait() {
  local timeout="" after="" all=0 types=$ACTIONABLE
  resolve_monitor "$1"; shift
  while [ $# -gt 0 ]; do
    case $1 in
      --timeout) [ $# -ge 2 ] || die "--timeout requires a value"; timeout=$(parse_duration "$2") || die "bad --timeout '$2'"; shift 2 ;;
      --after) is_uint "${2:-}" || die "--after expects a sequence number"; after=$2; shift 2 ;;
      --types) [ $# -ge 2 ] || die "--types requires a value"; types=$2; shift 2 ;;
      --all) all=1; shift ;;
      *) die "unknown wait option '$1'" ;;
    esac
  done
  [ -n "$after" ] || after=$(cat "$MDIR/cursor" 2>/dev/null)
  is_uint "$after" || after=0
  local start=$SECONDS out max found dead_checked=0
  while :; do
    out=$(awk -v after="$after" -v types=",$types," -v all="$all" '
      match($0, /^\{"seq":[0-9]+/) {
        s = substr($0, 8, RLENGTH - 7) + 0; if (s > max) max = s
        if (s <= after) next
        t = $0; sub(/^\{"seq":[0-9]+,"type":"/, "", t); sub(/".*/, "", t)
        if (all || index(types, "," t ",")) print
      }
      END { print "#MAX " max + 0 }' "$EVENTS" 2>/dev/null)
    max=$(printf '%s\n' "$out" | sed -n 's/^#MAX //p'); is_uint "$max" || max=$after
    found=$(printf '%s\n' "$out" | grep -v '^#MAX ')
    if [ -n "$found" ]; then
      printf '%s\n' "$found"
      echo "$max" > "$MDIR/cursor"
      case $found in
        *'"type":"threshold"'*) exit 2 ;;
        *'"type":"collect_error"'*|*'"type":"unreachable"'*) exit 3 ;;
        *'"type":"target_exit"'*) exit 4 ;;
        *'"type":"stopped"'*|*'"type":"monitor_died"'*) exit 5 ;;
      esac
      exit 0
    fi
    if ! monitor_alive; then
      if [ "$dead_checked" = 1 ]; then
        if ! grep -q '"type":"stopped"' "$EVENTS" 2>/dev/null; then
          emit_offline monitor_died "\"message\":\"monitor process is gone without a stopped event\""
          tail -n 1 "$EVENTS"
          echo "$SEQ" > "$MDIR/cursor"
          exit 5
        fi
        # already stopped before our cursor: report that instead of blocking forever
        printf '{"type":"no_events","cursor":%s,"monitor_alive":false}\n' "$max"
        exit 5
      fi
      dead_checked=1; continue
    fi
    if [ -n "$timeout" ] && [ $((SECONDS - start)) -ge "$timeout" ]; then
      echo "$max" > "$MDIR/cursor"
      printf '{"type":"no_events","cursor":%s,"monitor_alive":true}\n' "$max"
      exit 0
    fi
    sleep 1
  done
}

cmd_events() {
  local after=0 type=""
  resolve_monitor "$1"; shift
  while [ $# -gt 0 ]; do
    case $1 in
      --after) is_uint "${2:-}" || die "--after expects a sequence number"; after=$2; shift 2 ;;
      --type) [ $# -ge 2 ] || die "--type requires a value"; type=$2; shift 2 ;;
      *) die "unknown events option '$1'" ;;
    esac
  done
  awk -v after="$after" -v type="$type" '
    match($0, /^\{"seq":[0-9]+/) {
      s = substr($0, 8, RLENGTH - 7) + 0; if (s <= after) next
      if (type != "" && index($0, "\"type\":\"" type "\"") == 0) next
      print
    }' "$EVENTS" 2>/dev/null
}

cmd_status() {
  resolve_monitor "$1"
  local alive=false pid
  monitor_alive && alive=true
  pid=$(cat "$MDIR/pid" 2>/dev/null); is_uint "$pid" || pid=null
  printf '{"monitor_id":%s,"alive":%s,"pid":%s,"dir":%s,"state":%s}\n' "$(jstr "$MONITOR_ID")" "$alive" "$pid" \
    "$(jstr "$MDIR")" "$(cat "$MDIR/state.json" 2>/dev/null || echo null)"
}

cmd_note() {
  resolve_monitor "$1"; shift
  local msg="" reset=0 pid=""
  while [ $# -gt 0 ]; do
    case $1 in
      --reset-baseline) reset=1; shift ;;
      --pid) case ${2:-} in ''|*[!0-9,]*) die "--pid expects PID[,PID]" ;; esac; pid=$2; shift 2 ;;
      -*) die "unknown note option '$1'" ;;
      *) msg="${msg:+$msg }$1"; shift ;;
    esac
  done
  [ -n "$msg" ] || die "note needs a MESSAGE describing the intervention"
  msg=$(printf '%s' "$msg" | tr '\n\r' '  ')
  if monitor_alive; then
    local tmp="$MDIR/ctl/.$$.tmp"
    mkdir -p "$MDIR/ctl"
    printf 'reset=%s\npid=%s\nmsg=%s\n' "$reset" "$pid" "$msg" > "$tmp" && mv "$tmp" "$MDIR/ctl/$(date +%s)-$$.ctl"
    echo '{"queued":true}'
  else
    emit_offline intervention "\"message\":$(jstr "$msg"),\"reset_baseline\":false,\"monitor_alive\":false"
    tail -n 1 "$EVENTS"
    echo "$PROG: monitor is not running; intervention recorded only" >&2
  fi
}

stop_one() {
  local pid i
  if ! monitor_alive; then
    grep -q '"type":"stopped"' "$EVENTS" 2>/dev/null || emit_offline stopped "\"reason\":\"already_dead\""
    rm -f "$MDIR/pid"
    printf '{"monitor_id":%s,"stopped":true,"was_running":false}\n' "$(jstr "$MONITOR_ID")"
    return
  fi
  pid=$(cat "$MDIR/pid")
  kill -TERM "$pid" 2>/dev/null
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 15 ]; do sleep 1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    emit_offline stopped "\"reason\":\"killed\""
    rm -f "$MDIR/pid"
  fi
  printf '{"monitor_id":%s,"stopped":true,"was_running":true}\n' "$(jstr "$MONITOR_ID")"
}

cmd_stop() {
  [ -n "${1:-}" ] || die "stop needs <monitor> or --all"
  if [ "$1" = --all ]; then
    local d
    for d in "$RESMON_HOME"/*/; do
      [ -f "$d/meta" ] || continue
      MDIR=${d%/}; MONITOR_ID=$(basename "$MDIR"); EVENTS="$MDIR/events.jsonl"
      monitor_alive && stop_one
    done
    return 0
  fi
  resolve_monitor "$1"
  stop_one
}

cmd_list() {
  local d alive last
  for d in "$RESMON_HOME"/*/; do
    [ -f "$d/meta" ] || continue
    MDIR=${d%/}; MONITOR_ID=$(basename "$MDIR"); EVENTS="$MDIR/events.jsonl"
    alive=false; monitor_alive && alive=true
    last=$(tail -n 1 "$EVENTS" 2>/dev/null | sed -n 's/^{"seq":[0-9]*,"type":"\([a-z_]*\)".*/\1/p')
    printf '{"monitor_id":%s,"alive":%s,"task_id":%s,"machine":%s,"created_at":%s,"last_event":%s}\n' \
      "$(jstr "$MONITOR_ID")" "$alive" "$(jstr "$(meta_get task_id)")" "$(jstr "$(meta_get machine)")" \
      "$(jstr "$(meta_get created_at)")" "$( [ -n "$last" ] && jstr "$last" || echo null)"
  done
}

main() {
  local cmd=${1:-}
  [ $# -gt 0 ] && shift
  case $cmd in
    start) cmd_start "$@" ;;
    run) cmd_run "$@" ;;
    check) cmd_check "$@" ;;
    wait) cmd_wait "$@" ;;
    events) cmd_events "$@" ;;
    status) cmd_status "$@" ;;
    note) cmd_note "$@" ;;
    stop) cmd_stop "$@" ;;
    list) cmd_list ;;
    _daemon) cmd_daemon "$@" ;;
    -h|--help|help) usage ;;
    '') usage >&2; exit 1 ;;
    *) echo "$PROG: unknown command '$cmd'" >&2; usage >&2; exit 1 ;;
  esac
}

main "$@"
