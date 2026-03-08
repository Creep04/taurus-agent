#!/usr/bin/env bash

# Load nvm to ensure we have access to the correct Node.js version for Gemini
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm

gemini --approval-mode=yolo --prompt "$(cat system_prompt.md)"
