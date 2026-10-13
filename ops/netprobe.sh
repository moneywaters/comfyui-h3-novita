#!/bin/bash
# Diagnose upload throughput to a ComfyUI GPU instance.
#
# Hypothesis under test: the ~0.1-0.85 MB/s we measured is a per-connection limit on the
# path (proxy hop and/or TCP window + slow start), not the real capacity of the box. If so,
# N concurrent uploads should give roughly N x the throughput, and a direct connection that
# bypasses the HTTP proxy should be faster still.
#
#   ./netprobe.sh <gui-url> [direct-ip:port]
#
# Prints a table; makes no changes to the instance.
set -uo pipefail

U="${1:?usage: netprobe.sh <gui-url> [direct-ip:port]}"
DIRECT="${2:-}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

say() { printf '\n== %s ==\n' "$*"; }
row() { printf '  %-34s %10s %10s %10s\n' "$1" "$2" "$3" "$4"; }

mbfile() { # $1 = MB, $2 = path
    python3 -c "
import os,sys
open(sys.argv[2],'wb').write(os.urandom(1024)*(1024*int(sys.argv[1])))" "$1" "$2"
}

# curl -w fields we care about, as one line
FMT='%{http_code} %{size_upload} %{time_total} %{speed_upload} %{time_connect} %{time_starttransfer}'

upload() { # $1 = file, $2 = extra curl args
    local f="$1"; shift
    curl -s -o /dev/null --max-time 600 "${@}" -X POST \
        -F "image=@$f;filename=$(basename "$f")" -F "overwrite=true" \
        -F "subfolder=netprobe" -F "type=input" \
        -w "$FMT" "$U/upload/image" 2>/dev/null
}

say "latency"
for i in 1 2 3; do
    curl -s -o /dev/null --max-time 40 -w "  connect=%{time_connect}s  ttfb=%{time_starttransfer}s  total=%{time_total}s\n" "$U/"
done

say "small-file overhead (is there a fixed cost per request?)"
mbfile 1 "$W/one.bin" 2>/dev/null || python3 -c "
open('$W/one100k.bin','wb').write(b'0'*(100*1024))"
for sz in 0.1 1; do
    if [ "$sz" = "0.1" ]; then f="$W/one100k.bin"; else f="$W/one.bin"; fi
    [ -f "$f" ] || continue
    out=$(upload "$f")
    echo "  $sz MB -> $(echo "$out" | awk '{printf "HTTP %s  sent=%s B  %.2fs  %.2f MB/s", $1,$2,$3,$4/1048576}')"
done

say "single-stream upload (2 MB, 8 MB)"
for mb in 2 8; do
    f="$W/s$mb.bin"; mbfile "$mb" "$f"
    out=$(upload "$f")
    echo "  ${mb} MB -> $(echo "$out" | awk '{printf "HTTP %s  %.2fs  %.2f MB/s", $1,$3,$4/1048576}')"
    echo "$out" | awk '{print $4/1048576}' >> "$W/single.txt"
done

say "4-way parallel upload (4 x 2 MB) -- does it scale?"
for i in 1 2 3 4; do mbfile 2 "$W/p$i.bin"; done
start=$(python3 -c 'import time;print(time.time())')
for i in 1 2 3 4; do
    upload "$W/p$i.bin" > "$W/p$i.out" &
done
wait
end=$(python3 -c 'import time;print(time.time())')
tot=$(python3 -c "print(8.0/($end-$start))")
echo "  4 x 2 MB = 8 MB in $(python3 -c "print(round($end-$start,2))")s  ->  ${tot} MB/s aggregate"
for i in 1 2 3 4; do
    awk -v i="$i" '{printf "    stream %d: HTTP %s  %.2fs  %.2f MB/s\n", i, $1, $3, $4/1048576}' "$W/p$i.out"
done

say "download throughput (same path, reverse direction)"
# a large-ish file the server already has: /object_info is ~3.25 MB uncompressed
curl -s -o /dev/null --max-time 300 -w "  /api/object_info -> %{size_download} B in %{time_total}s = %{speed_download} B/s\n" \
    -H 'Accept-Encoding: identity' "$U/api/object_info"
# and something from the input folder we just uploaded
curl -s -o /dev/null --max-time 300 -w "  /view 8 MB      -> %{size_download} B in %{time_total}s = %{speed_download} B/s\n" \
    "$U/view?filename=s8.bin&subfolder=netprobe&type=input"

if [ -n "$DIRECT" ]; then
    say "direct connection (bypassing the HTTP proxy): $DIRECT"
    for i in 1 2 3; do
        curl -s -o /dev/null --max-time 40 -w "  connect=%{time_connect}s  ttfb=%{time_starttransfer}s  total=%{time_total}s\n" "http://$DIRECT/"
    done
    f="$W/s8.bin"
    out=$(curl -s -o /dev/null --max-time 300 -X POST \
        -F "image=@$f;filename=direct8.bin" -F "overwrite=true" \
        -F "subfolder=netprobe" -F "type=input" -w "$FMT" "http://$DIRECT/upload/image" 2>/dev/null)
    echo "  8 MB direct -> $(echo "$out" | awk '{printf "HTTP %s  %.2fs  %.2f MB/s", $1,$3,$4/1048576}')"
fi

say "summary"
if [ -f "$W/single.txt" ]; then
    best=$(sort -g "$W/single.txt" | tail -1)
    echo "  best single-stream: ${best} MB/s"
    echo "  4-way aggregate:    ${tot} MB/s"
    printf '  scaling factor:     %s\n' "$(python3 -c "print(round($tot/max($best,0.0001),2))")x"
fi