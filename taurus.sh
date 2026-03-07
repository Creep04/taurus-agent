#!/bin/bash

# If Taurus is already running, stop it before starting a new instance
if pgrep -x "taurus.sh" > /dev/null; then
  echo "Stopping existing Taurus instance..."
  pkill -x "taurus.sh"
  # Wait a moment to ensure the process has terminated
  sleep 5
fi

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
