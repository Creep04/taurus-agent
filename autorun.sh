#!/usr/bin/env bash
# Runs `taurus.sh` on a schedule with webhook support, serialized execution,
# and timeout enforcement.

set -euo pipefail

# Configuration
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1

COMMAND="taurus.sh"               # Script located next to autorun.sh
INTERVAL=$((15 * 60))             # Seconds between scheduled runs (15 min)
TIMEOUT=$((30 * 60))              # Max allowed runtime before kill (30 min)
WEBHOOK_PORT=9876                 # Port to listen for webhook POST requests
WEBHOOK_PATH="/resend-trigger"    # HTTP path that triggers a run
SVIX_SECRET="whsec_..."           # Svix webhook secret (set to empty to disable verification)
SVIX_TOLERANCE=300                # Allowed webhook clock drift in seconds

# State files
# Stored in /tmp so they disappear on reboot.
PENDING_FILE="/tmp/taurus-runner.pending"
REQUEST_METHOD=
REQUEST_PATH=
REQUEST_BODY=
REQUEST_SVIX_ID=
REQUEST_SVIX_TIMESTAMP=
REQUEST_SVIX_SIGNATURE=

# Signal handling
WEBHOOK_TRIGGERED=0
trap 'WEBHOOK_TRIGGERED=1' USR1

# Lifecycle helpers
cleanup() {
  kill "${WEBHOOK_PID:-}" 2>/dev/null || true
  rm -f "$PENDING_FILE"
}

trap cleanup EXIT
trap 'echo "Runner shutting down."; exit 130' INT
trap 'echo "Runner shutting down."; exit 143' TERM

constant_time_equals() {
  local left=$1
  local right=$2
  local index=0
  local diff=0
  local left_char
  local right_char

  if (( ${#left} != ${#right} )); then
    return 1
  fi

  while (( index < ${#left} )); do
    printf -v left_char '%d' "'${left:index:1}"
    printf -v right_char '%d' "'${right:index:1}"
    diff=$(( diff | (left_char ^ right_char) ))
    ((index += 1))
  done

  (( diff == 0 ))
}

compute_svix_signature() {
  local message=$1
  local secret_bytes_hex

  secret_bytes_hex=$(printf '%s' "${SVIX_SECRET#whsec_}" | openssl base64 -d -A 2>/dev/null | od -An -tx1 -v | tr -d ' \n') || return 1
  [[ -n "$secret_bytes_hex" ]] || return 1

  printf '%s' "$message" |
    openssl dgst -sha256 -mac HMAC -macopt "hexkey:$secret_bytes_hex" -binary 2>/dev/null |
    openssl base64 -A 2>/dev/null
}

reset_webhook_request() {
  REQUEST_METHOD=
  REQUEST_PATH=
  REQUEST_BODY=
  REQUEST_SVIX_ID=
  REQUEST_SVIX_TIMESTAMP=
  REQUEST_SVIX_SIGNATURE=
}

read_webhook_request() {
  local request_line=
  local header_line=
  local header_name=
  local header_value=
  local content_length=0

  reset_webhook_request

  IFS= read -r request_line || request_line=
  request_line=${request_line%$'\r'}
  read -r REQUEST_METHOD REQUEST_PATH _ <<<"$request_line"

  while IFS= read -r header_line; do
    header_line=${header_line%$'\r'}
    [[ -z "$header_line" ]] && break

    header_name=${header_line%%:*}
    header_value=${header_line#*:}
    header_value=${header_value# }

    case "${header_name,,}" in
      content-length)
        content_length=$header_value
        ;;
      svix-id|webhook-id)
        REQUEST_SVIX_ID=$header_value
        ;;
      svix-timestamp|webhook-timestamp)
        REQUEST_SVIX_TIMESTAMP=$header_value
        ;;
      svix-signature|webhook-signature)
        REQUEST_SVIX_SIGNATURE=$header_value
        ;;
    esac
  done

  if [[ "$content_length" =~ ^[0-9]+$ ]] && (( content_length > 0 )); then
    REQUEST_BODY=$(dd bs=1 count="$content_length" 2>/dev/null)
  fi
}

verify_svix_request() {
  local current_time
  local time_skew
  local signed_content
  local expected_signature=
  local signature_entry=
  local signature_value=

  [[ "$REQUEST_METHOD" == "POST" ]] || return 1
  [[ "$REQUEST_PATH" == "$WEBHOOK_PATH" ]] || return 1
  [[ -n "$REQUEST_SVIX_ID" && -n "$REQUEST_SVIX_TIMESTAMP" && -n "$REQUEST_SVIX_SIGNATURE" ]] || return 1
  [[ "$REQUEST_SVIX_TIMESTAMP" =~ ^[0-9]+$ ]] || return 1

  current_time=$(date +%s)
  time_skew=$(( current_time - REQUEST_SVIX_TIMESTAMP ))
  if (( time_skew < 0 )); then
    time_skew=$(( -time_skew ))
  fi

  (( time_skew <= SVIX_TOLERANCE )) || return 1

  signed_content="$REQUEST_SVIX_ID.$REQUEST_SVIX_TIMESTAMP.$REQUEST_BODY"
  expected_signature=$(compute_svix_signature "$signed_content") || return 1

  for signature_entry in $REQUEST_SVIX_SIGNATURE; do
    [[ "$signature_entry" == v1,* ]] || continue
    signature_value=${signature_entry#v1,}

    if constant_time_equals "$signature_value" "$expected_signature"; then
      return 0
    fi
  done

  return 1
}

send_webhook_response() {
  local authorized=$1
  local response_status='401 Unauthorized'
  local response_body='UNAUTHORIZED'

  if (( authorized )); then
    response_status='200 OK'
    response_body='AUTHORIZED'
  fi

  printf 'HTTP/1.1 %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
    "$response_status" "${#response_body}" "$response_body"
}

trigger_webhook_run() {
  local main_pid=$1

  echo "Verified Svix webhook; signalling main loop."
  touch "$PENDING_FILE"
  kill -USR1 "$main_pid" 2>/dev/null || true
}

# Execute the command with timeout enforcement and pending-trigger handling.
# This script assumes a single autorun.sh instance managed by the service.
run_command() {
  echo "Starting $COMMAND."

  # Run the script located alongside autorun.sh.
  "$COMMAND" &
  local cmd_pid=$!
  echo "$COMMAND started (PID $cmd_pid)."

  # Kill the child if it runs longer than the configured timeout.
  (
    sleep "$TIMEOUT"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      echo "TIMEOUT: killing $COMMAND (PID $cmd_pid) after ${TIMEOUT}s."
      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 5
      kill -KILL "$cmd_pid" 2>/dev/null || true
    fi
  ) &
  local watchdog_pid=$!

  # Wait for the command to finish before allowing another run.
  wait "$cmd_pid" 2>/dev/null || true
  kill "$watchdog_pid" 2>/dev/null || true   # cancel watchdog if cmd exited early

  echo "$COMMAND finished."

  # If a webhook arrived while the script was running, honour it now.
  if [[ -f "$PENDING_FILE" ]]; then
    rm -f "$PENDING_FILE"
    echo "Pending webhook trigger found; re-running $COMMAND now."
    run_command
  fi
}

# Webhook server (bash + nc + openssl)
# Listens for signed HTTP POST requests to WEBHOOK_PATH on WEBHOOK_PORT and
# signals the main loop through PENDING_FILE + SIGUSR1.
start_webhook_server() {
  local main_pid=$$

  (
    echo "Webhook server listening on port $WEBHOOK_PORT (POST $WEBHOOK_PATH, Svix verified)."

    while true; do
      # Read one HTTP request, verify it, then send the response.
      {
        read_webhook_request

        if verify_svix_request; then
          trigger_webhook_run "$main_pid"
          send_webhook_response 1
        else
          send_webhook_response 0
        fi
      } | nc -l -p "$WEBHOOK_PORT" -q 1 2>/dev/null || true
    done
  ) &
  WEBHOOK_PID=$!
}

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required for Svix verification."
  exit 1
}

echo "autorun for $COMMAND started (interval=${INTERVAL}s, timeout=${TIMEOUT}s, webhook=:${WEBHOOK_PORT}${WEBHOOK_PATH})."
start_webhook_server

next_run=0

while true; do
  now=$(date +%s)

  if (( now >= next_run )) || (( WEBHOOK_TRIGGERED )); then
    WEBHOOK_TRIGGERED=0
    rm -f "$PENDING_FILE"
    run_command
    next_run=$(( $(date +%s) + INTERVAL ))
    echo "Next scheduled run at $(date -d "@$next_run" '+%H:%M:%S' 2>/dev/null || date -r "$next_run" '+%H:%M:%S')."
  fi

  # Sleep until the next scheduled run, but wake up early on SIGUSR1.
  sleep_for=$(( next_run - $(date +%s) ))

  if (( sleep_for > 0 )); then
    sleep "$sleep_for" &
    sleep_pid=$!

    # wait returns when either the sleep ends or a signal arrives
    wait "$sleep_pid" 2>/dev/null || true
  fi
done