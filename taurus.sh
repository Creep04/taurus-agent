#!/usr/bin/env bash

PID_FILE="/tmp/taurus-agent.pid"

# If Taurus was already running, stop that recorded instance before starting a new one.
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "--- Stopping existing Taurus instance: $(cat "$PID_FILE") ---"
  kill -INT "$(cat "$PID_FILE")" 2>/dev/null || true
  sleep 5
fi

echo "$$" > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

# Load environment variables from .env if it exists
[ -f .env ] && set -a && source .env && set +a

# Load nvm to ensure we have access to the correct Node.js version for Gemini
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm

echo "--- Starting Run: $(date -u +'%Y-%m-%dT%H:%M:%SZ') ---
"

gemini --approval-mode=yolo --prompt "$(cat system_prompt.md)"

echo "--- Run Complete ---
"
