#!/usr/bin/env bash
#=============================================================================
# perf-compare.sh — Wave-5 runtime performance measurement of the NATIVE
# engine (Release build). The mpv comparison leg was removed at Wave 6
# (mpv deleted from the app); the historical mpv-vs-native numbers are
# recorded in KANBAN.md. Headless: direct binary launch + osascript file
# delivery + ps sampling + NSLog timestamp parsing. No sudo, no GUI.
#
# Usage: Tests/Scripts/perf-compare.sh [--clip /path/to/silent.mkv]
#
#   Default clip: /tmp/perf-clip.mkv (generated if missing: 120 s, 640x360,
#   30 fps, h264 High, no audio — silent by construction).
#
# Measures (Release):
#   - app binary size (app + native ThirdParty libs)
#   - native: RSS (peak/mean) + CPU (mean/range) over a ~20 s window
#   - native: launch-to-first-frame and open-to-first-frame
#   - native: seek latency via the resume path (store position 60 s -> open
#     -> exact seek -> first post-seek logged frame; pacing-corrected)
#   - native: presented-frame count vs expected (drop inference)
#
# Energy (powermetrics) requires sudo — deliberately not attempted.
#=============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="${APP_DIR:-${REPO_ROOT}/build/ReleaseDD/Build/Products/Release/Player.app}"
BIN="${APP_DIR}/Contents/MacOS/Player"
BUNDLE_ID="devplaceholder.U6PPSBV8.Player"
CLIP="${1:-/tmp/perf-clip.mkv}"
SEEK_TARGET=60.0
FPS=30.0
SAMPLE_SECS=20

# NOTE: since the sandbox card (App Sandbox ON), the SwiftData store lives in
# the app container (~/Library/Containers/...), which the CLI cannot read or
# write (container protection). Resume positions are therefore primed by
# PLAYING (the app autosaves and reports "[Native] saved position X" on its
# own stdout), not by sqlite3 injection.

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -x "$BIN" ]] || fail "app binary not found: $BIN (build Release first)"

if [[ ! -f "$CLIP" ]]; then
  echo "==> generating silent clip $CLIP"
  ffmpeg -y -f lavfi -i testsrc2=duration=120:size=640x360:rate=30 -an \
    -c:v libx264 -pix_fmt yuv420p -profile:v high "$CLIP" >/dev/null 2>&1 \
    || fail "ffmpeg clip generation failed"
fi

#---- helpers ----------------------------------------------------------------
kill_app() { pkill -x Player 2>/dev/null; sleep 2; }

# Prime a resume position by PLAYING the clip until the app's own autosave
# log reaches >= target seconds, then quit gracefully (fires the final save).
# Progress goes to stderr; STDOUT carries ONLY the primed position (so the
# caller can capture it as a bare number). Log -> $1.
prime_resume() {
  local target="$1" log="$2" pid saved=""
  kill_app
  echo "==> priming resume to >= ${target}s" >&2
  "$BIN" >"$log" 2>&1 &
  pid=$!
  sleep 2.5
  osascript -e "tell application id \"$BUNDLE_ID\" to open POSIX file \"$CLIP\"" \
    >/dev/null 2>&1 || echo "    (osascript open returned nonzero — continuing)" >&2
  # Poll the app's own saved-position log (autosave every 5 s) until target.
  for i in $(seq 1 60); do
    sleep 3
    saved="$(grep '\[Native\] saved position' "$log" | tail -1 | grep -o 'saved position [0-9.]*' | awk '{print $3}')"
    [[ -n "$saved" ]] && awk -v s="$saved" -v t="$target" 'BEGIN{ exit !(s >= t) }' && break
  done
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
  sleep 2
  kill_app
  [[ -n "$saved" ]] || fail "prime_resume: never saw a saved position in $log (tail: $(tail -2 "$log"))"
  echo "  primed resume position: $saved s (target >= $target)" >&2
  echo "$saved"
}

# launch app (optionally with env), deliver clip, sample, quit; log -> $1
run_engine() {
  local name="$1" envvar="$2" log="$3" pid="" line
  kill_app
  echo "==> run: $name (env=${envvar:-default})"
  if [[ -n "$envvar" ]]; then
    env $envvar "$BIN" >"$log" 2>&1 &
  else
    "$BIN" >"$log" 2>&1 &
  fi
  pid=$!
  sleep 2.5                                   # app init + window
  osascript -e "tell application id \"$BUNDLE_ID\" to open POSIX file \"$CLIP\"" \
    >/dev/null 2>&1 || echo "    (osascript open returned nonzero — continuing)"
  sleep 1
  # sample RSS (KB) + CPU (%) every second
  local rss_peak=0 rss_sum=0 cpu_sum=0 cpu_min=999 cpu_max=0 n=0
  for i in $(seq 1 "$SAMPLE_SECS"); do
    line="$(ps -o rss=,pcpu= -p "$pid" 2>/dev/null)" || break
    rss="$(echo "$line" | awk '{print $1}')"
    cpu="$(echo "$line" | awk '{print $2}')"
    rss_sum=$((rss_sum + rss)); [[ $rss -gt $rss_peak ]] && rss_peak=$rss
    cpu_sum=$(awk -v a="$cpu_sum" -v b="$cpu" 'BEGIN{print a+b}')
    cpu_min=$(awk -v a="$cpu_min" -v b="$cpu" 'BEGIN{print (b<a)?b:a}')
    cpu_max=$(awk -v a="$cpu_max" -v b="$cpu" 'BEGIN{print (b>a)?b:a}')
    n=$((n + 1))
    sleep 1
  done
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
  sleep 2
  kill_app
  [[ $n -gt 0 ]] || fail "no samples for $name (app died early?)"
  echo "  $name: RSS peak=${rss_peak} KB mean=$((rss_sum / n)) KB; CPU mean=$(awk -v s="$cpu_sum" -v n="$n" 'BEGIN{printf "%.1f", s/n}')% range=${cpu_min}->${cpu_max}% (n=$n)"
}

#---- 1. binary size ----------------------------------------------------------
echo "==> binary size"
du -h "$BIN" | awk '{print "  app binary:", $1}'
echo "  ThirdParty/FFmpeg libs: $(du -sh "$REPO_ROOT/ThirdParty/FFmpeg/lib" | awk '{print $1}') (native playback contribution)"

#---- 2. native engine run (RSS/CPU) ------------------------------------------
run_engine "native" "" "/tmp/perf-native.log"

#---- 3. native timing (launch-to-first-frame, drops) --------------------------
LOG=/tmp/perf-native.log
grep -q '\[Native\] presented frame' "$LOG" || fail "no presented-frame lines (did the clip play?)"

python3 - "$LOG" "$SEEK_TARGET" "$FPS" <<'PY'
import re, sys, datetime
log, target, fps = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])

def ts(line):
    m = re.match(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)', line)
    if not m: return None
    return datetime.datetime.strptime(m.group(1)[:26], '%Y-%m-%d %H:%M:%S.%f').timestamp()

launch_t = probe_t = opened_t = None
frames = []
for line in open(log):
    t = ts(line)
    if t is None: continue
    if launch_t is None: launch_t = t
    m = re.search(r'presented frame (\d+) at pts=([\d.]+) clock=([\d.]+)', line)
    if m:
        frames.append((t, int(m.group(1)), float(m.group(2)), float(m.group(3))))
    elif '[Native] probe begin' in line:
        probe_t = t
    elif '[Native] opened' in line:
        opened_t = t

if not frames:
    print('  no frames parsed'); sys.exit(1)

t0, n0, p0, c0 = frames[0]
print(f'  first logged frame: #{n0} pts={p0:.3f} clock={c0:.3f}')
print(f'  launch->first-frame: {(t0 - launch_t) * 1000:.0f} ms (first NSLog line -> frame #1; includes ~2.5 s app init + osascript delivery)')
if probe_t is not None:
    print(f'  open->first-frame:   {(t0 - probe_t) * 1000:.0f} ms (probe begin -> frame #1)')

# drops: frame-index delta between first and last logged frame vs wall window
if len(frames) >= 4:
    win_start, win_end = frames[1][0], frames[-1][0]
    presented = frames[-1][1] - frames[1][1]
    expected = (win_end - win_start) * fps
    print(f'  steady-state: {win_end - win_start:.1f} s window, {presented} frames presented (#{frames[1][1]}->#{frames[-1][1]}), expected ~{expected:.0f} (delta {presented - expected:+.0f})')

# seek latency: first post-seek logged frame (pts within 10 s of the target).
# The log's clock = media time at presentation; the wall moment the clock hit
# the target is ts - (clock - target), which needs no pacing assumptions
# (the engine presents a catch-up burst right after the seek).
first_after = next((f for f in frames if f[2] >= target - 10), None)
if first_after and opened_t is not None:
    t, n, p, c = first_after
    lat = (t - opened_t) - (c - target)
    print(f'  seek latency (resume path, target {target:.0f}s): {lat * 1000:.0f} ms'
          f' (logged frame #{n} pts={p:.3f} clock={c:.3f}, clock-correction {(c - target):.3f} s)')
PY

#---- 4. seek latency via resume path (native) --------------------------------
echo "==> seek-latency run (resume target ${SEEK_TARGET}s)"
PRIMED="$(prime_resume "$SEEK_TARGET" /tmp/perf-prime.log)" || exit 1
TARGET="${PRIMED:-$SEEK_TARGET}"
LOG=/tmp/perf-seek.log
kill_app
"$BIN" >"$LOG" 2>&1 &
pid=$!
sleep 2.5
osascript -e "tell application id \"$BUNDLE_ID\" to open POSIX file \"$CLIP\"" >/dev/null 2>&1
sleep 7                                        # enough for open + seek + first post-seek frame
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
sleep 2
kill_app
grep -q '\[Native\] presented frame' "$LOG" || fail "no presented-frame lines in seek run"

python3 - "$LOG" "$TARGET" "$FPS" <<'PY'
import re, sys, datetime
log, target, fps = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])

def ts(line):
    m = re.match(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)', line)
    if not m: return None
    return datetime.datetime.strptime(m.group(1)[:26], '%Y-%m-%d %H:%M:%S.%f').timestamp()

opened_t = None
frames = []
for line in open(log):
    t = ts(line)
    if t is None: continue
    m = re.search(r'presented frame (\d+) at pts=([\d.]+) clock=([\d.]+)', line)
    if m:
        frames.append((t, int(m.group(1)), float(m.group(2)), float(m.group(3))))
    elif '[Native] opened' in line:
        opened_t = t

if not frames or opened_t is None:
    print('  seek run: no frames/opened line parsed'); sys.exit(1)
print(f'  seek run frames: ' + ', '.join(f'#{n}@{p:.1f}' for _, n, p, _ in frames))
first_after = next((f for f in frames if f[2] >= target - 10), None)
if first_after is None:
    print(f'  seek run: no frame within 10 s of target {target} (pts range {frames[0][2]:.2f}..{frames[-1][2]:.2f})'); sys.exit(1)
t, n, p, c = first_after
lat = (t - opened_t) - (c - target)
print(f'  seek latency (resume path, target {target:.0f}s): {lat * 1000:.0f} ms'
      f' (first post-seek logged frame #{n} pts={p:.3f} clock={c:.3f}, clock-correction {(c - target):.3f} s)')
PY

echo "==> done"
