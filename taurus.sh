#!/bin/bash

# Load environment variables from .env if it exists
[ -f .env ] && set -a && source .env && set +a

# Load nvm to ensure we have access to the correct Node.js version for Gemini
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm

echo "--- Starting Run: $(date -u +'%Y-%m-%dT%H:%M:%SZ') ---
"

gemini --approval-mode=yolo --prompt $(cat system_prompt.md)

echo "--- Run Complete ---
"