#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# start_qemu_container
# Pulls latest RISC-V QEMU Ubuntu image and launches container
# Args:
#   $1 - container name
#   $2 - work directory (mounted to /workspace)
#   $3 - log directory (mounted to /var/log/qemu)
#   $4 - image name (e.g., cloudv10x/riscv-qemu-ubuntu:latest)
# ------------------------------------------------------------
start_qemu_container() {
  local container_name="$1"
  local work_dir="$2"
  local log_dir="$3"
  local image_name="$4"

  echo "🔹 Pulling latest RISC-V QEMU Ubuntu image..."
  docker pull "${image_name}"

  echo "🔹 Starting container: ${container_name}"
  docker run -d \
    --name "${container_name}" \
    --privileged \
    -v "${work_dir}":/workspace \
    -v "${log_dir}":/var/log/qemu \
    -e AUTO_ATTACH=0 \
    -e RUN_TESTS=0 \
    cloudv10x/riscv-qemu-ubuntu:latest

  echo "✓ Container started: ${container_name}"
}



# ------------------------------------------------------------
# wait_for_qemu_boot
# Waits for the QEMU system to boot and be ready for commands
# Args:
#   $1 - container name
#   $2 - console log path (optional)
#   $3 - timeout in seconds (optional, default: 600)
#   $4 - interval in seconds (optional, default: 5)
# ------------------------------------------------------------

wait_for_qemu_boot() {
  local container_name="${1:?container name required}"
  local console_log="${2:-}"
  local timeout="${3:-600}"
  local interval="${4:-5}"

  local attempts=$(( timeout / interval ))
  local i=1
  local progress_every=$(( 100 / interval )); (( progress_every == 0 )) && progress_every=1

  echo "Waiting for QEMU boot completion (timeout=${timeout}s, interval=${interval}s)..."

  while (( i <= attempts )); do
    # 1) Container still running?
    if ! docker ps --format '{{.Names}}' | grep -qx "${container_name}"; then
      echo "ERROR: Container stopped unexpectedly: ${container_name}"
      docker logs "${container_name}" --tail 100 || true
      return 1
    fi

    # 2) Console log signals (preferred)
    if [[ -n "${console_log}" && -f "${console_log}" ]]; then
      if tail -n 100 "${console_log}" | tr -d '\r' | grep -qE 'RISC-V Ubuntu image is ready\.|System is ready for headless operation'; then
        echo "System ready (matched in console log)"
        return 0
      fi
    fi

    # 3) Fallback: container logs
    if docker logs "${container_name}" 2>&1 | tail -n 200 | tr -d '\r' | \
       grep -qE 'RISC-V Ubuntu image is ready\.|System is ready for headless operation'; then
      echo "System ready (matched in container logs)"
      return 0
    fi

    # Progress every ~100s
    if (( i % progress_every == 0 )); then
      echo "  Still booting... $(( i * interval ))s elapsed"
    fi

    sleep "${interval}"
    (( i++ ))
  done

  echo "ERROR: Boot timeout after ${timeout}s"
  echo "=== Last 200 docker log lines ==="
  docker logs "${container_name}" --tail 200 || true
  return 1
}


# ------------------------------------------------------------
# setup_guest_interface
# Sets up the command interface for the qemu system riscv64 Ubuntu guest
# Args:
#   $1 - container name
#   $2 - guest FIFO path (optional, default: /var/log/qemu/guest.in)
#   $3 - console log path (optional, default: /var/log/qemu/console.log)
# ------------------------------------------------------------
setup_guest_interface() {
  local container_name="${1:?container name required}"
  local guest_fifo="${2:-/var/log/qemu/guest.in}"
  local console_log="${3:-/var/log/qemu/console.log}"

  echo "Setting up headless command interface for '${container_name}'..."

  # --- Verify PTY path file exists ---
  if ! docker exec "${container_name}" test -f /var/log/qemu/pty.path; then
    echo "ERROR: PTY path file not found in /var/log/qemu/pty.path"
    return 1
  fi

  local pty_path
  pty_path="$(docker exec "${container_name}" cat /var/log/qemu/pty.path)"
  echo "   Guest PTY: ${pty_path}"

  # --- Create FIFO for command input if missing ---
  docker exec "${container_name}" bash -c "
    [ -p '${guest_fifo}' ] || mkfifo '${guest_fifo}'
    chmod 666 '${guest_fifo}'
  "

  # --- Start background FIFO -> PTY bridge ---
  docker exec -d "${container_name}" bash -c "
    PTY=\$(cat /var/log/qemu/pty.path)
    while true; do
      [ -p '${guest_fifo}' ] && [ -c \"\${PTY}\" ] && cat '${guest_fifo}' > \"\${PTY}\" || sleep 1
    done
  " 2>/dev/null

  sleep 2

  # --- Verify bridge process is active ---
  if docker exec "${container_name}" pgrep -f "cat ${guest_fifo}" >/dev/null; then
    echo "✓ Command bridge active"
  else
    echo "WARNING: Bridge process not detected (commands may not work)"
  fi

  # --- Basic command test ---
  echo "Testing command interface..."
  local probe="__TEST_$(date +%s)__"

  # Send command via FIFO
  docker exec "${container_name}" bash -c "printf '%s\n' 'echo ${probe}' > '${guest_fifo}'"

  sleep 2

  # Verify response in console log
  if docker exec "${container_name}" grep -q "${probe}" "${console_log}"; then
    echo "✓ Command interface verified"
    return 0
  else
    echo "ERROR: Command interface test failed (probe not found in console log)"
    return 1
  fi
}

# ------------------------------------------------------------
# send_cmd
# Sends a command to the guest system via the specified FIFO
# Args:
#   $1 - container name
#   $2 - guest FIFO path (optional, default: /var/log/qemu/guest.in)
#   $3 - command string
# ------------------------------------------------------------
send_cmd() {
  local container_name="${1:?container name required}"
  local guest_fifo="${2:-/var/log/qemu/guest.in}"
  local cmd="${3:?command string required}"

  docker exec "${container_name}" bash -c "printf '%s\n' \"$cmd\" > '${guest_fifo}'"
}


# ------------------------------------------------------------
# run_guest
# Runs a command in the guest and captures its output between unique markers
# Args:
#   $1 - container name
#   $2 - guest FIFO path (optional, default: /var/log/qemu/guest.in)
#   $3 - console log path (optional, default: /var/log/qemu/console.log)
#   $4 - command string
#   $5 - timeout in seconds (optional, default: 30)
# ------------------------------------------------------------
run_guest() {
  local container_name="${1:?container name required}"
  local guest_fifo="${2:?guest FIFO path required}"
  local console_log="${3:?console log path required}"
  local cmd="${4:?command string required}"
  local timeout="${5:-30}"

  echo "→ ${cmd}"

  # Create unique markers for this command
  local uid
  uid="$(date +%s%N)-$RANDOM"
  local START="__START_${uid}__"
  local END="__END_${uid}__"

  # Command wrapped with markers
  local wrapped="{ echo ${START}; ${cmd}; echo ${END}; } 2>&1"

  # Start background tail + AWK capture
  timeout "${timeout}"s tail -n0 -F "${console_log}" 2>/dev/null | \
    awk -v s="${START}" -v e="${END}" '
      BEGIN { active=0 }
      {
        if (index($0, s)) { active=1; next }
        if (index($0, e)) { exit 0 }
        if (active) print
      }
    ' &
  local awk_pid=$!

  # Allow tail to attach
  sleep 0.3

  # Send the wrapped command
  send_cmd "${container_name}" "${guest_fifo}" "${wrapped}"

  # Wait for capture to finish
  wait "${awk_pid}" 2>/dev/null || true
  echo ""
}