---
name: resmon
description: Background resource guard for a long-running task on a remote (SSH) or local Linux machine. Set limits before starting the task, launch a detached monitor bound to the task's PID tree or cgroup, and get structured events (threshold, collect_error, unreachable, target_exit) back in the foreground so you can adjust the process you are running or debugging. Covers task CPU/RSS/leak rate/processes/disk I/O, plus machine CPU, load, memory, swap, PSI, OOM kills, disk space, inodes and disk I/O (util, await, MiB/s, IOPS).
---

# resmon (`resmon.sh`)

Watches the CPU, memory and disk usage of **one task** on a Linux machine in the background. When a limit is crossed it writes a structured event, and you (the foreground agent) use that event to adjust the task.

- Controller side (your side): `bash` 3.2+ and `awk`.
- Target side: POSIX `sh` + `awk` + `/proc`. The probe goes over a single SSH connection's stdin, is read-only, and writes no files on the target.

## How it runs

```
1. start   set limits, bind to the task process, start in the background → returns monitor_id at once
2. wait    block (or poll) until an actionable event arrives → JSON event + exit code
3. act     act on the event's metric / context.task_top / hint (lower batch size, kill a worker, free disk, ...)
4. note    record what you did (can reset the baseline or switch to a new PID)
5. stop    stop explicitly when the task ends; the monitor also stops itself when the target exits or the TTL runs out
```

## Quick start

```bash
# 0) Start the task first and get its PID (e.g. launched on the remote machine with nohup)
PID=$(ssh h200 'cd /work && nohup python train.py > train.log 2>&1 & echo $!')

# 1) Start the monitor (returns immediately; stdout is the handle JSON)
./resmon.sh start h200 --task-id RUN-123 --pid "$PID" --interval 30 \
  --limit task_rss_gib=64,task_cpu_pct=800,cpu=95%,memory=90% \
  --disk /data=92 --limit disk_util_pct=95
# => {"monitor_id":"RUN-123-20261030-153000-4242","pid":4242,"event_file":".../events.jsonl",
#     "state_file":".../state.json","wait_cmd":"... wait RUN-123-...", ...}

# 2) Wait for an event (from another terminal / background task)
./resmon.sh wait RUN-123            # blocks until there is an actionable event
./resmon.sh wait RUN-123 --timeout 0  # non-blocking check

# 3) After acting, record it
./resmon.sh note RUN-123 "batch size 64 -> 32, restarted" --pid "$NEW_PID"

# 4) Finish
./resmon.sh stop RUN-123
```

`<monitor>` can be the full monitor_id or just the task id (the task's newest monitor is used).

### Recommended pattern for Claude Code
Run `wait` with the Bash tool's `run_in_background: true`. The command exits on an actionable event and the harness notifies you automatically, so you can keep working and don't need to poll. After handling the event, start `wait` in the background again. `wait` keeps a cursor, so it never returns the same event twice.

For other agents: run `wait <id> --timeout 0` between steps of your work. Exit code 0 means nothing new.

## Choosing the target (what task-level limits apply to)

| Option | Meaning |
|---|---|
| `--pid PID[,PID]` | Process tree rooted at PID (descendants found through PPid; zombies excluded) |
| `--pid-file PATH` | PID file on the target machine, re-read every sample; a changed PID resets the baseline automatically |
| `--cgroup PATH` | cgroup v2 (e.g. `/user.slice/run-123.scope` or a `systemd-run --scope` unit). Memory = `memory.current - inactive_file`; CPU/IO come from `cpu.stat`/`io.stat`, which also counts children that already exited |
| (none) | Machine-level limits only; task metrics are empty |

With a cgroup the measurement is most accurate. You can start the task with `systemd-run --user --scope --unit=run123 python train.py` and use `--cgroup /user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice/run123.scope`; check the actual path with `cat /proc/<pid>/cgroup`.

## Events (`events.jsonl`, one JSON object per line, `seq` increasing)

Every event has `seq,type,at,monitor_id,task_id,machine`.

| type | Wakes `wait` | Meaning |
|---|---|---|
| `started` | | Monitor started; includes target, limits, interval |
| `threshold` | ✅ exit 2 | Over a limit. Fields: `metric, scope(task/machine/disk), path, observed, limit, unit, sustained_samples, repeat, message, hint, context{summary, task{…, top:[pid,rss_gib,cpu_pct,cmd]}, top_users}` |
| `recovered` | | A metric that was over its limit is back under it |
| `collect_error` | ✅ exit 3 | Collection problem (e.g. `disk_df` on a missing path, `pidfile_unreadable`, `awk_missing`); reported once when it starts |
| `collect_warning` | | Partial data that needs no action (`task_io_unreadable`: some processes' `/proc/<pid>/io` can't be read) |
| `collect_recovered` | | That collection problem / warning has cleared |
| `sample_failed` | | One SSH/probe failure (`attempt`, `error`) |
| `unreachable` | ✅ exit 3 | `unreachable` failures in a row (default 3) |
| `reachable` | | Back after being unreachable (followed by `baseline_reset`) |
| `baseline_reset` | | Leak-rate baseline reset; `reason`: `collection_gap` / `intervention` / `retarget` / `target_changed` |
| `intervention` | | Written by `note`: `message, reset_baseline, retarget` |
| `target_exit` | ✅ exit 4 | Target process/cgroup is gone (the monitor then stops itself) |
| `stopped` | ✅ exit 5 | `reason`: `requested` / `target_exit` / `ttl` / `alert` / `unreachable` / `crashed` / `killed` |
| `monitor_died` | ✅ exit 5 | Monitor process vanished without a `stopped` event (written by `wait`) |

Use `wait --all` to wake on every event, or `--types threshold,recovered` to choose; `--after SEQ` sets the cursor yourself.

`threshold` repeats every `realert` samples (default 10) while the problem lasts (`repeat` counts up), and `recovered` follows when it clears. Rate metrics (CPU, load, iowait, disk util/await/throughput, task CPU/IO) must stay over the limit for `sustain` samples in a row (default 2) before they fire. Memory, disk space and OOM fire right away.

## How to act on events

- `scope=task`: your own process is the cause. Look at `context.task.top` (pid, rss, cpu, cmd) and `hint`. Typical actions: lower batch size / `num_workers` / thread count, add memory release, restart the leaking worker. Then `note`.
- `scope=machine`: first compare `context.task.rss_pct` / `cpu_pct` with `context.top_users`. If your task only has a small share, another user is filling the machine. Lower your own load or report it; don't blame your own process.
- `scope=disk`: `disk_used_pct` / `disk_inodes_pct` → clean up or move checkpoints/logs. `disk_util_pct` / `disk_await_ms` / throughput → lower checkpoint frequency, cut log volume, slow down data loading.
- `collect_error` / `unreachable`: monitoring is blind, not a resource problem. Check SSH or paths before deciding whether to keep going.
- `target_exit`: the task has ended (normally or by crash). Check the task's own logs and exit code.

## Limits (`--limit KEY=VALUE`, comma-separated or repeated; 0 disables)

| Key | Default | Meaning |
|---|---|---|
| `task_rss_gib` (`task_mem`) | 0 | Total task memory (GiB; accepts `64GiB`/`512MiB`/`1TiB`) |
| `task_rss_pct` | 0 | Task memory as % of machine RAM |
| `task_mem_limit_pct` | 90 | Task memory as % of the cgroup `memory.max` (cgroup targets only) |
| `task_rss_growth_gib_per_min` | 4 | Task memory growth rate (leak detection) |
| `task_cpu_pct` (`task_cpu`) | 0 | Task CPU, 100 = one core |
| `task_procs` / `task_threads` | 0 | Task process / thread count |
| `task_read_mibps` / `task_write_mibps` | 0 | Task disk read/write MiB/s (`/proc/<pid>/io` or cgroup `io.stat`) |
| `task_oom_new` | 1 | New OOM kills inside the task cgroup |
| `cpu_busy_pct` (`cpu`) | 95 | Machine CPU busy % |
| `load_per_cpu` (`load`) | 1.5 | load1 / CPUs |
| `iowait_pct` (`iowait`) | 0 | CPU iowait % |
| `mem_used_pct` | 85 | Machine memory % (`memory=90%` maps here, `memory=64GiB` maps to `task_rss_gib`) |
| `swap_used_pct` (`swap`) | 40 | Swap % |
| `psi_mem_full_avg10` (`psi`) | 5 | Memory PSI full avg10 |
| `psi_io_full_avg10` | 0 | I/O PSI full avg10 |
| `oom_kill_new` | 1 | New OOM kills on the machine |
| `disk_used_pct` (`disk`) | 92 | Disk space %; `--disk /data=95` or `disk=/data:95%` sets a per-path value |
| `disk_inodes_pct` | 95 | inode % |
| `disk_util_pct` (`disk_util`) | 0 | Device busy % (like iostat %util) |
| `disk_await_ms` (`disk_await`) | 0 | Average I/O wait in ms |
| `disk_read_mibps` / `disk_write_mibps` | 0 | Device throughput |
| `sustain` / `realert` / `unreachable` | 2 / 10 / 3 | Consecutive samples / repeat period / failures before unreachable |

Other options: `--interval 30s` (default 30s), `--window 1` (seconds of CPU/IO measurement window per sample), `--ttl 24h` (default; 0 = never stop on its own), `--stop-on-alert`, `--disk PATH[=PCT]` (repeatable, default `/`). The `RESMON_LIMITS="k=v,k=v"` environment variable supplies default limits.

Disk I/O metrics need the path to sit on a block device (matched via `stat` st_dev / `df` device name against `/proc/diskstats`). NFS, overlay, tmpfs and similar report `null` and raise no alert.

## Other commands

```bash
./resmon.sh check h200 --pid 1234 --limit task_mem=64GiB   # one sample: first line is the sample JSON, then events; exit 0/2/3/4
./resmon.sh run   h200 --pid 1234                          # foreground loop, events on stdout
./resmon.sh status RUN-123                                 # {"alive":..,"state":{latest sample, active breaches, errors}}
./resmon.sh events RUN-123 --after 10 --type threshold
./resmon.sh list                                           # all monitors (JSONL)
./resmon.sh stop --all
```

## Exit codes

`0` OK / nothing new · `1` usage or environment error (e.g. bad option, `local` used on a non-Linux machine) · `2` threshold · `3` collection failure / unreachable · `4` target exited · `5` monitor stopped or died

## Files

`${RESMON_HOME:-~/.local/state/resmon}/<monitor_id>/` (permissions 700):
`events.jsonl` events · `samples.jsonl` every sample · `state.json` latest state · `monitor.log` daemon stderr · `pid` · `cursor` (wait cursor) · `ctl/` (queue that `note` writes into).

## Limitations

- The target must be Linux (`/proc`). cgroup support is v2 only.
- The target must have `awk` (gawk/mawk/busybox all work). The old pure-sh fallback was removed.
- PID-tree CPU/IO is measured inside the window and only counts processes alive in that window. Use `--cgroup` when you need CPU/IO accounting that includes short-lived children.
- `/proc/<pid>/io` is only readable for processes of the same user; when it can't be read you get `collect_warning: task_io_unreadable`, and task I/O is partial (with a cgroup target whose io.stat is readable, io.stat is used and this doesn't happen).

Upstream tests (`tests/run.sh`, fake `/proc` + canned probe) are not vendored into this repository; see `workflow/skills/UPSTREAM.md`. In this project, `scripts/remote run` starts resmon automatically on each job's pid file (procedure: the `remote-run` skill).
