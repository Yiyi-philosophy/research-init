# Remote Compute

Reference for `scripts/remote`, the thin adapter (ssh + tmux + rsync + Clash API) that runs long jobs on the project's remote host. The step-by-step supervision procedure is the `remote-run` skill. Host names, ports and paths here are deployment config; they never enter Protocol, Decision or Evidence semantics.

## 1. Configuration

Values come from `project.yaml` (`project.slug` and the `remote` section). Environment variables override them for a single shell.

| `project.yaml` key | Override | Default | Meaning |
| --- | --- | --- | --- |
| `project.slug` | `RW_PROJECT_SLUG` | required | Namespace on the shared host; commands that touch it refuse to run while unset |
| `remote.host` | `RW_HOST` | required | ssh alias from `~/.ssh/config` |
| `remote.workdir` | `RW_WORKDIR` | `~/<slug>` | Code mirror on the host |
| `remote.runs_root` | `RW_RUNS_DIR` (full per-project path) | `~/rw-runs` | Job directories `<runs_root>/<slug>/<run_id>/` |
| `remote.output_dirs` | `RW_OUTPUT_DIRS` | `results output` | Written on the host, pulled back, never synced forward |
| `remote.proxy` | `RW_PROXY` | `http://127.0.0.1:7890` | Host-local proxy, mixed-port (HTTP and SOCKS5) |
| `remote.clash_api` | `RW_CLASH_API` | `http://127.0.0.1:9999` | Clash external-controller on the host |
| `remote.resmon_limits` | `RW_RESMON_LIMITS` | resmon defaults | `--limit` passed to resmon, e.g. `task_mem=20GiB,disk=90%` |
| — | `RW_CLASH_SECRET` | empty | Controller secret; set it in your shell only, never in the repository |
| — | `RW_SSH`, `RW_RESMON`, `RW_CONFIG` | `ssh`, bundled resmon, `project.yaml` | Used by tests |

On the host, each job gets:

- directory `<runs_root>/<slug>/<run_id>/` with `job.sh` (the script that runs), `cmd.txt` (the original command), `pid` and `run.log` (stdout + stderr);
- tmux session `rw-<slug>-<run_id>`;
- environment variable `RW_RUN_ID`.

`run_id` is never reused: `run` refuses an id whose log already exists. Use the experiment manifest's `run_id` (for example `EXP-001`).

## 2. Code sync (local → host)

Code is changed only in the local working tree. The host's workdir is a mirror updated by rsync; no commit or push is needed.

- `run` syncs before starting; `sync` syncs alone; `sync --dry-run` shows what would change. Do a dry run before the first sync to a host directory.
- The working tree is copied as is (including uncommitted and untracked files), compared by content (`rsync -c`). Files deleted locally are deleted on the host.
- Never touched on the host: `.git/`, paths ignored by `.gitignore`, and the output dirs. Anything a job writes elsewhere in the workdir is deleted by the next sync.
- Each sync writes `.rw-sync` on the host: `src=<machine> commit=<HEAD> dirty=<yes|no> tree=<fingerprint> synced_at=...`. `tree` hashes HEAD, the uncommitted diff and untracked file contents, so it identifies exactly which code ran.
- `run` writes the `.rw-sync` stamp into `__RW_START__`. With `--no-sync`, it warns if the host's code differs from the local tree.
- The host's `.git/` (if any) does not represent the current code. Do not use git on the host to judge versions, and do not edit code there.

## 3. Results (host → local)

- Jobs write only to the output dirs, preferably per run: `results/$RW_RUN_ID/`.
- `watch` pulls the output dirs back when the job ends (last event `__RW_PULLED__`; skip with `--no-pull`). `pull` does it on demand (`--dry-run` to preview). Pull copies incrementally and never deletes local files.
- `results/` holds metrics and small reports; it is tracked and can be cited as Evidence. `output/` holds checkpoints and predictions; it is ignored by git.
- `run.log` stays on the host (`scripts/remote logs`). A job that needs to keep key information writes it into `results/`.

## 4. Commands

```bash
scripts/remote check                                  # ssh, tmux, GPU, python3, proxy egress, Clash API
scripts/remote status                                 # load, GPUs, this project's running jobs
scripts/remote sync --dry-run                         # preview what sync would change or delete
scripts/remote run EXP-001 -- 'python train.py --out "results/$RW_RUN_ID"'   # sync, start, start resmon
scripts/remote run DL-001 --proxy -- 'pip install -r requirements.txt'        # job needs the proxy
scripts/remote watch EXP-001 --progress 'epoch [0-9]+' # event stream for the Monitor tool
scripts/remote logs EXP-001 100                       # last 100 log lines
scripts/remote stop EXP-001                           # Ctrl-C, kill after 15 s (--grace N)
scripts/remote pull                                   # pull output dirs now
```

Other `run` options: `--no-sync`, `--no-resmon`, `--workdir PATH` (implies `--no-sync`).

## 5. Event markers

| Marker | Meaning |
| --- | --- |
| `__RW_START__` | Job started: run_id, host, pid, sync stamp, time |
| `__RW_EXIT__ code=N` | Command finished with exit code N (97 = bad workdir) |
| `__RW_STOPPED__` | Stopped by `scripts/remote stop` |
| `__RW_DONE__` | Last `watch` event, with the final status; `__RW_GONE__` if the session ended without an exit marker |
| `__RW_WATCH_LOST__` / `__RW_WATCH_ERROR__` | ssh dropped / remote error (e.g. no log) |
| `__RW_PULLED__` | Output dirs pulled back after the job ended |

`watch` always matches failure signals (`Traceback`, `Error`, `Exception`, `Killed`, `OOM`, `out of memory`, `Segmentation fault`, `NaN`, ...) and all markers; `--progress RE` adds a few progress lines.

## 6. Proxy and node switching

- `run --proxy` sets `http_proxy` / `https_proxy` / `all_proxy` (and upper-case variants) to `remote.proxy` and excludes localhost. For a one-off command:

  ```bash
  ssh <host> 'export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890; <command>'
  ```

- Node switching uses the Clash API on the host (needs `python3` there; `check` reports it):

  ```bash
  scripts/remote proxy test                 # egress through the proxy
  scripts/remote proxy groups               # Selector groups and their current node
  scripts/remote proxy nodes <group>        # nodes in a group, * = current
  scripts/remote proxy delay <node>         # latency
  scripts/remote proxy use <group> <node>   # switch and read back (prints before / after)
  ```

- Switching affects **all** proxied traffic on the host, including other projects' running jobs. Check `status` first, and write the before and after nodes into the task report.

## 7. Relation to the research workflow

- `run.log` is an execution fact. Cite it as Evidence only after checking it, with `run_id`, host and the `commit` / `dirty` / `tree` stamp from `__RW_START__`.
- Experiment manifests record the host in `environment.host`.
- If the host is unreachable, write `Current reproduction unavailable`; never downgrade existing evidence to `Unverified`.

## 8. Host requirements

- Local machine: `bash`, `git`, `rsync`, `ssh` with the host alias in `~/.ssh/config` (key-based, since `BatchMode=yes`).
- Remote host: Linux, `bash`, `tmux`, `rsync`, `awk` (for resmon); `python3` for proxy commands; `curl` and `nvidia-smi` are optional (checks only).
- Proxy and Clash are optional: the defaults above are examples; set `remote.proxy` / `remote.clash_api` to match the host, or ignore the proxy commands.
- A host may be shared by several projects: always rely on the per-project namespace (`~/<slug>`, `~/rw-runs/<slug>/`, `rw-<slug>-*`). Never point `remote.workdir` at another project's mirror: sync deletes files that are not in this working tree.
