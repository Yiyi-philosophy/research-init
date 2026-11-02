#!/usr/bin/env bash
# Exercises scripts/remote against a fake ssh that runs the remote side locally,
# a private tmux server and a fake Clash external-controller.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
remote_bin="$repo_root/scripts/remote"
tmp="$(mktemp -d)"
export TMUX_TMPDIR="$tmp/tmux"; mkdir -p "$TMUX_TMPDIR"
clash_pid=""
cleanup() {
  tmux kill-server 2>/dev/null || true
  [[ -z "$clash_pid" ]] || kill "$clash_pid" 2>/dev/null || true
  rm -rf -- "$tmp"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
expect() { grep -qE -- "$2" <<<"$3" || { printf '%s\n' "$3" >&2; fail "$1: missing /$2/"; }; }
reject() { if grep -qE -- "$2" <<<"$3"; then printf '%s\n' "$3" >&2; fail "$1: unexpected /$2/"; fi; }

cat > "$tmp/ssh" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 && $1 == -o ]]; do shift 2; done
shift
exec bash -c "$*"
EOF
chmod +x "$tmp/ssh"
# Isolate from the repository's project.yaml: fixed slug, default host name.
export RW_CONFIG="$tmp/no-project.yaml" RW_PROJECT_SLUG=demo RW_HOST=testhost
export RW_SSH="$tmp/ssh" RW_RUNS_DIR="$tmp/runs" RW_WORKDIR="$tmp" RW_RESMON="$tmp/resmon"
cat > "$tmp/resmon" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${0%/*}/resmon.calls"
printf '{"monitor_id":"%s-fake","pid":1}\n' "$4"
EOF
chmod +x "$tmp/resmon"

# run -> watch: failure line and exit marker are reported, ordinary output is filtered out
"$remote_bin" run t1 --no-sync -- 'echo hello; echo "Traceback: boom"; exit 3' >/dev/null 2>&1
out="$("$remote_bin" watch t1 --no-pull)"
expect "watch t1" '__RW_START__ run_id=t1' "$out"
expect "watch t1" 'Traceback: boom' "$out"
expect "watch t1" '__RW_EXIT__ run_id=t1 code=3' "$out"
expect "watch t1" '__RW_DONE__ run_id=t1' "$out"
reject "watch t1" '^hello$' "$out"

# --progress adds lines; multi-line commands with quotes survive the ssh hop
"$remote_bin" run t2 --no-sync -- 'for i in 1 2; do echo "epoch $i loss=0.$i"; done
echo "it'"'"'s fine"' >/dev/null 2>&1
out="$("$remote_bin" watch t2 --no-pull --progress 'epoch [0-9]+')"
expect "watch t2" 'epoch 2 loss=0.2' "$out"
expect "watch t2" 'code=0' "$out"
[[ "$(cat "$tmp/runs/t2/cmd.txt")" == *"it's fine"* ]] || fail "cmd.txt lost quoting"

# resmon is started on the job's pid file; --no-resmon skips it
grep -q "^start testhost --task-id t1 --pid-file $tmp/runs/t1/pid$" "$tmp/resmon.calls" || { cat "$tmp/resmon.calls" >&2; fail "resmon not started for t1"; }
[[ "$(cat "$tmp/runs/t1/pid")" =~ ^[0-9]+$ ]] || fail "job did not write its pid"
out="$("$remote_bin" run t1b --no-sync --no-resmon -- true 2>/dev/null)"
grep -q 't1b' "$tmp/resmon.calls" && fail "--no-resmon still started resmon"
"$remote_bin" watch t1b --no-pull >/dev/null

# duplicate run_id and invalid run_id are refused
if "$remote_bin" run t1 --no-sync -- true >/dev/null 2>&1; then fail "duplicate run_id accepted"; fi
if "$remote_bin" run 'bad id' --no-sync -- true >/dev/null 2>&1; then fail "invalid run_id accepted"; fi

# stop: a long job is interrupted and watch still ends with a terminal event
"$remote_bin" run t3 --no-sync -- 'sleep 300' >/dev/null 2>&1
"$remote_bin" status | grep -q 'running t3' || fail "status does not list t3"
# another project's session on the same host is not listed; commands refuse an uninitialized project
tmux new-session -d -s rw-other-x 'sleep 300'
"$remote_bin" status | grep -q 'running x' && fail "status lists another project's job"
tmux kill-session -t =rw-other-x
if RW_PROJECT_SLUG= "$remote_bin" status >/dev/null 2>&1; then fail "status ran without project.slug"; fi
if RW_HOST= "$remote_bin" check >/dev/null 2>&1; then fail "check ran without remote.host"; fi
"$remote_bin" stop t3 --grace 5 >/dev/null
out="$("$remote_bin" watch t3 --no-pull --lines 50)"
expect "watch t3" '__RW_STOPPED__ run_id=t3' "$out"
expect "watch t3" '__RW_DONE__ run_id=t3' "$out"

# killed session without exit marker is reported as GONE, not silence
"$remote_bin" run t4 --no-sync -- 'sleep 300' >/dev/null 2>&1
tmux kill-session -t =rw-demo-t4
out="$("$remote_bin" watch t4 --no-pull)"
expect "watch t4" '__RW_GONE__' "$out"

# missing log is an explicit event and a nonzero exit
if out="$("$remote_bin" watch nope --no-pull)"; then fail "watch on missing run succeeded"; fi
expect "watch nope" '__RW_WATCH_ERROR__' "$out"

# sync: rsync of the working tree (committed or not), .gitignore'd paths and .git on the host are left alone
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$tmp/local/scripts/lib" "$tmp/remote-wd/out" "$tmp/remote-wd/.git"
git -C "$tmp/local" init -q
cp "$remote_bin" "$tmp/local/scripts/remote"; cp "$repo_root/scripts/lib/project-config.sh" "$tmp/local/scripts/lib/"; printf 'out/\n' > "$tmp/local/.gitignore"; echo v1 > "$tmp/local/a.txt"
git -C "$tmp/local" add -A; git -C "$tmp/local" commit -qm init
echo ckpt > "$tmp/remote-wd/out/model.pt"; echo keep > "$tmp/remote-wd/.git/HEAD"; echo stale > "$tmp/remote-wd/stale.txt"
export RW_WORKDIR="$tmp/remote-wd"
lremote="$tmp/local/scripts/remote"
dry="$("$lremote" sync --dry-run)"
expect "dry-run" 'deleting +stale.txt' "$dry"
reject "dry-run" 'deleting +out' "$dry"
[[ -f "$tmp/remote-wd/stale.txt" ]] || fail "dry-run deleted files"
echo v2 > "$tmp/local/a.txt"; echo new > "$tmp/local/untracked.txt"     # uncommitted + untracked
out="$("$lremote" sync)"
expect "sync" 'dirty=yes' "$out"
[[ "$(cat "$tmp/remote-wd/a.txt")" == v2 && -f "$tmp/remote-wd/untracked.txt" ]] || fail "sync did not copy working tree"
[[ ! -e "$tmp/remote-wd/stale.txt" ]] || fail "sync did not delete removed file"
[[ -f "$tmp/remote-wd/out/model.pt" ]] || fail "sync deleted a .gitignore'd path"
[[ "$(cat "$tmp/remote-wd/.git/HEAD")" == keep ]] || fail "sync touched the host .git"
fp="$(grep -o 'tree=[0-9a-f]*' "$tmp/remote-wd/.rw-sync")"
echo v3 > "$tmp/local/a.txt"
"$lremote" sync >/dev/null
[[ "$(grep -o 'tree=[0-9a-f]*' "$tmp/remote-wd/.rw-sync")" != "$fp" ]] || fail "fingerprint did not change with content"
# run syncs by default and records the stamp; --no-sync after a local edit warns
echo v4 > "$tmp/local/a.txt"
"$lremote" run t5 -- 'cat a.txt' >/dev/null 2>&1
out="$("$lremote" watch t5 --progress '^v[0-9]')"
expect "watch t5" '__RW_START__ .*commit=[0-9a-f]{12} dirty=yes tree=' "$out"
expect "watch t5" '^v4$' "$out"
echo v5 > "$tmp/local/a.txt"
warn="$("$lremote" run t6 --no-sync -- true 2>&1 >/dev/null)"
expect "run t6 warning" 'remote code differs' "$warn"
warn="$("$lremote" run t7 -- true 2>&1 >/dev/null)"
reject "run t7" 'differs' "$warn"
# pull: results/ and output/ come back when watch ends; sync never deletes or overwrites them on the host
"$lremote" run t9 -- 'mkdir -p results/t9 output; echo acc=0.9 > results/t9/metrics.txt; echo w > output/model.bin' >/dev/null 2>&1
out="$("$lremote" watch t9)"
expect "watch t9" '__RW_PULLED__ run_id=t9 pulled 2 file' "$out"
[[ "$(cat "$tmp/local/results/t9/metrics.txt")" == acc=0.9 && -f "$tmp/local/output/model.bin" ]] || fail "pull did not bring results back"
echo local-note > "$tmp/local/results/local-only.txt"
"$lremote" sync >/dev/null
[[ -f "$tmp/remote-wd/results/t9/metrics.txt" && -f "$tmp/remote-wd/output/model.bin" ]] || fail "sync deleted host outputs"
[[ ! -e "$tmp/remote-wd/results/local-only.txt" ]] || fail "sync pushed results/ to the host"
out="$("$lremote" watch t9 --no-pull)"
reject "watch --no-pull" '__RW_PULLED__' "$out"
rm -rf "$tmp/remote-wd/results" "$tmp/remote-wd/output"
expect "pull nothing" 'pulled nothing' "$("$lremote" pull)"
export RW_WORKDIR="$tmp"

# proxy commands against a fake Clash API
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
cat > "$tmp/clash.py" <<'EOF'
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
state = {'proxies': {'节点选择': {'type': 'Selector', 'now': 'HK-01', 'all': ['HK-01', 'JP-02']},
                     'auto': {'type': 'URLTest', 'now': 'HK-01', 'all': ['HK-01']},
                     'HK-01': {'type': 'Shadowsocks'}, 'JP-02': {'type': 'Shadowsocks'}}}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj=None):
        body = json.dumps(obj).encode() if obj is not None else b''
        self.send_response(code); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        u = urllib.parse.urlparse(self.path); parts = [urllib.parse.unquote(p) for p in u.path.split('/') if p]
        if self.headers.get('Authorization') != 'Bearer s3cret': return self.send(401, {'message': 'Unauthorized'})
        if parts == ['version']: return self.send(200, {'version': 'fake'})
        if parts == ['proxies']: return self.send(200, state)
        if len(parts) == 2: return self.send(200, state['proxies'][parts[1]])
        if len(parts) == 3 and parts[2] == 'delay': return self.send(200, {'delay': 42})
        self.send(404, {'message': 'not found'})
    def do_PUT(self):
        parts = [urllib.parse.unquote(p) for p in self.path.split('/') if p]
        name = json.loads(self.rfile.read(int(self.headers['Content-Length'])))['name']
        g = state['proxies'][parts[1]]
        if name not in g['all']: return self.send(400, {'message': 'Selector update error: proxy not exist'})
        g['now'] = name; self.send(204)
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
EOF
python3 "$tmp/clash.py" "$port" & clash_pid=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.1; done
export RW_CLASH_API="http://127.0.0.1:$port" RW_CLASH_SECRET=s3cret

out="$("$remote_bin" proxy groups)"
expect "groups" '^节点选择	now=HK-01' "$out"
reject "groups" '^auto' "$out"
expect "nodes" '^\* HK-01' "$("$remote_bin" proxy nodes 节点选择)"
expect "use" 'before=HK-01 after=JP-02' "$("$remote_bin" proxy use 节点选择 JP-02)"
expect "nodes after use" '^\* JP-02' "$("$remote_bin" proxy nodes 节点选择)"
if "$remote_bin" proxy use 节点选择 NOPE >/dev/null 2>&1; then fail "switch to unknown node succeeded"; fi
expect "delay" 'delay_ms=42' "$("$remote_bin" proxy delay JP-02)"
if RW_CLASH_SECRET=wrong "$remote_bin" proxy groups >/dev/null 2>&1; then fail "wrong secret accepted"; fi

printf 'ok: remote adapter tests\n'
