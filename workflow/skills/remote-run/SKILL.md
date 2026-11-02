---
name: remote-run
description: Launch and supervise a long job (about 2 minutes or more, or detached) on the project's remote compute host with scripts/remote, a Monitor watch on job progress and a background resmon wait on resources. Use for training, evaluation, data downloads or large syncs, when re-attaching to running jobs at session start, and when a watch or resmon event arrives.
---

# Remote run

Every long job on the remote host is supervised by two background channels. Each does one thing:

| | `watch` (Claude Code `Monitor` tool) | `resmon` (skill `resmon`) |
| --- | --- | --- |
| Watches | The job itself: progress lines, errors (Traceback, OOM messages, NaN, ...), exit code | Resources: memory, leak rate, CPU, disk space and I/O, OOM kills, swap, for the job's process tree and the machine |
| Started with | `Monitor(command: "scripts/remote watch <run_id>", timeout_ms: 1800000)` | Bash with `run_in_background: true`: `workflow/skills/resmon/resmon.sh wait <run_id>` |
| Wakes you on | Each matching log line; `__RW_DONE__` means the job ended | Threshold crossed (exit 2), collection failure or unreachable (exit 3), job exited (exit 4), monitor stopped (exit 5) |
| When the job ends | Pulls `results/` and `output/` back (`__RW_PULLED__`) | Stops itself |

`watch` answers "what is the job doing, has it ended"; `resmon` answers "is the job exhausting the machine". Do not grep watch output to guess resource problems, and do not treat resmon's `target_exit` as success: the job's result is `__RW_EXIT__ code=`.

Configuration, sync semantics, markers and proxy commands: `docs/REMOTE-COMPUTE.md`.

## Preconditions

1. The `Monitor` tool is available (in Claude Code it may be deferred: load it with `ToolSearch` query `select:Monitor`). **Without Monitor, do not start long remote jobs**; run only short commands and say why.
2. `project.slug` is set in `project.yaml` (the script refuses otherwise).
3. `scripts/remote check` passes (ssh, tmux, GPU, proxy, Clash API).

## Session start: re-attach to running jobs

Run `scripts/remote status`. For each running job of this project, attach both channels with `watch <run_id> --lines 50` and `resmon.sh wait <run_id>` (`resmon.sh list` shows existing monitors).

## Launch

1. Choose a new `run_id` (reuse the experiment manifest's id, e.g. `EXP-001`; ids are never reused).
2. Make sure the job writes only to `results/$RW_RUN_ID/` or `output/$RW_RUN_ID/`. Anything else in the workdir is deleted by the next sync.
3. Start it (syncs first, then starts resmon on the job's pid file):

   ```bash
   scripts/remote run EXP-001 -- 'python train.py --out "results/$RW_RUN_ID"'
   ```

   Add `--proxy` if the job needs internet access. Per-job resource limits: `RW_RESMON_LIMITS=task_mem=20GiB,disk=90% scripts/remote run ...` (or `remote.resmon_limits` in `project.yaml`).
4. Attach both channels **immediately**, not when you need the result:

   ```text
   Monitor(
     command: "scripts/remote watch EXP-001 --progress 'epoch [0-9]+'",
     description: "EXP-001: progress / errors / exit",
     timeout_ms: 1800000
   )

   Bash(run_in_background: true,
        command: "workflow/skills/resmon/resmon.sh wait EXP-001")
   ```

   `--progress` should match a few lines per minute at most; matching every step floods the Monitor and gets it stopped.

## Handling events

| Event | Action |
| --- | --- |
| Failure line (Traceback, Error, OOM, NaN, ...) | Read `scripts/remote logs <run_id> 100`; decide whether the job is failing; `scripts/remote stop <run_id>` if so |
| `__RW_DONE__` | The job ended and results were pulled. The verdict is the `__RW_EXIT__ code=` inside it (`__RW_GONE__` means it died without an exit marker) |
| Monitor expired (30 min) without `__RW_DONE__` | Re-attach: `scripts/remote watch <run_id> --lines 50` |
| `__RW_WATCH_LOST__` | ssh dropped, not a job failure: `scripts/remote check`, then re-attach |
| resmon `threshold` | Act on `scope`, `context` and `hint` (see the `resmon` skill): `scope=task` → lower batch size / workers / threads; `scope=machine` → compare your share with `context.top_users` before blaming your job; `scope=disk` → clean up or slow down writes. Then `resmon.sh note <run_id> "<what you did>"` and run `wait` again in the background |
| resmon `unreachable` / `collect_error` | Monitoring is blind, not a resource problem: `scripts/remote check` first |
| resmon `target_exit` / `stopped` | resmon is done; the job's verdict still comes from watch |

resmon's `wait` returns one event per call: after handling it, start `wait` again in the background until `target_exit` or `stopped`.

## Proxy switching

`scripts/remote proxy use <group> <node>` affects all proxied traffic on the host, including other projects' running jobs. Check `scripts/remote status` first and write the `before` / `after` nodes into the task report.

## Reporting

- A job's log is an execution fact. Cite it as Evidence only after checking it, with `run_id`, host and the `commit` / `dirty` / `tree` stamp from `__RW_START__`. Flag `dirty=yes` results or reproduce them on committed code.
- Update the experiment manifest (`experiments/<run_id>.yaml`, format `workflow/templates/experiment.yaml`) when one exists, and `meta/status.yaml` + `docs/CURRENT.md` when evidence is accepted.
- If the host is unreachable, write `Current reproduction unavailable`; never downgrade existing evidence.
