#!/bin/bash
# Watchdog for the long fl2va download.
#
# A single curl invocation with --retry can exhaust its retries part-way through a
# 20 GB / 2-hour transfer across a flaky link and exit, leaving the file short. The
# fetcher's `-C -` makes every restart resume, so this just keeps re-launching it
# until the byte count matches upstream, then runs the finalizer.
#
# Safe to leave running; exits on its own once the pipeline is done.
set -u

F=/mnt/data/comfy-models/models/Comfy-Org--MiniMax-H3/snapshots/master/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors
EXPECT=20970379616
LOG="$HOME/v251-watchdog.log"
FETCH="$HOME/bin/fetch-v251-models.sh"

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }

have() { [ -f "$F" ] && stat -c%s "$F" 2>/dev/null || echo 0; }
fetching() { pgrep -f "fetch-v2[5]1-models" >/dev/null 2>&1; }

log "=== watchdog start (expect $EXPECT bytes) ==="
stall=0
last=0

for i in $(seq 1 400); do          # ~13 h ceiling at 2 min/poll
    n=$(have)
    if [ "$n" -ge "$EXPECT" ]; then
        log "fl2va COMPLETE ($n bytes) after $(( i * 2 )) min of watching"
        log "running finalizer"
        "$HOME/bin/finalize-v251.sh" >>"$LOG" 2>&1
        log "=== watchdog done ==="
        exit 0
    fi

    if ! fetching; then
        log "fetcher not running and file short ($n/$EXPECT) -> relaunching (resumes)"
        setsid nohup "$FETCH" >>"$HOME/v251-dl.log" 2>&1 </dev/null &
        sleep 20
        continue
    fi

    # notice a genuinely wedged transfer rather than a slow one
    if [ "$n" -eq "$last" ]; then
        stall=$(( stall + 1 ))
        [ "$stall" -ge 8 ] && {   # no growth for ~16 min
            log "no progress for ~16 min at $n bytes -> killing the stalled curl"
            for p in $(pgrep -f "curl .*minimax_h3_fl2va"); do kill "$p" 2>/dev/null; done
            for p in $(pgrep -f "fetch-v2[5]1-models"); do kill "$p" 2>/dev/null; done
            stall=0
        }
    else
        stall=0
    fi
    last="$n"

    awk -v n="$n" -v e="$EXPECT" 'BEGIN{printf "%s fl2va %.2f/%.2f GB (%.1f%%)\n","'"$(date -Is)"'", n/1e9, e/1e9, 100*n/e}' >>"$LOG"
    sleep 120
done

log "=== watchdog gave up after the loop ceiling ==="
exit 1
