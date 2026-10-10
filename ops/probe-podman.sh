#!/bin/bash
# Probe which container-build approach works on this (unprivileged) host.
set -uo pipefail
echo "=== identity ==="; id; echo "uid_map:"; cat /proc/self/uid_map
echo "cap_effective: $(grep CapEff /proc/self/status)"
echo "=== namespaces ==="
for ns in "-U" "-r" "-m" "-p -f --mount-proc"; do
  printf 'unshare %-18s -> ' "$ns"; unshare $ns true 2>&1 && echo OK || echo FAIL
done
echo "inside_userns:"; [ -e /proc/self/ns/user ] && ls -l /proc/self/ns/user
echo "=== fuse ==="; ls -l /dev/fuse 2>&1
echo "=== podman version ==="; podman --version; buildah --version 2>&1 | head -1

try() {  # label, env-string, cmd...
  local label="$1"; shift
  printf '\n--- %s ---\n' "$label"
  ( eval "$1"; shift; "$@" ) 2>&1 | tail -6
}

echo "=== attempts ==="
printf '\n--- A: plain podman info ---\n'; podman info >/dev/null 2>&1 && echo "A OK" || echo "A FAIL"

printf '\n--- B: _CONTAINERS_USERNS_CONFIGURED=1 ---\n'
env _CONTAINERS_USERNS_CONFIGURED=1 podman info >/dev/null 2>&1 && echo "B OK" || echo "B FAIL"

printf '\n--- C: vfs + cgroupfs ---\n'
podman --storage-driver vfs --cgroup-manager cgroupfs info >/dev/null 2>&1 && echo "C OK" || echo "C FAIL"

printf '\n--- D: B+C combined ---\n'
env _CONTAINERS_USERNS_CONFIGURED=1 podman --storage-driver vfs --cgroup-manager cgroupfs --events-backend file info >/dev/null 2>&1 && echo "D OK" || echo "D FAIL"

printf '\n--- E: podman login (with D env) ---\n'
env _CONTAINERS_USERNS_CONFIGURED=1 podman --storage-driver vfs --cgroup-manager cgroupfs login docker.io -u test -p test >/dev/null 2>&1 && echo "E OK" || echo "E FAIL"

printf '\n--- F: buildah info (vfs) ---\n'
env _CONTAINERS_USERNS_CONFIGURED=1 buildah --storage-driver vfs info >/dev/null 2>&1 && echo "F OK" || echo "F FAIL"

printf '\n--- G: error text for A ---\n'
podman info 2>&1 | tail -4

printf '\n--- H: storages/root writable ---\n'
ls -ld /var/lib/containers 2>&1; echo "HOME=$HOME"

printf '\n--- I: docker present? ---\n'
command -v docker dockerd 2>&1 || echo "no docker"
echo "PROBE DONE"
