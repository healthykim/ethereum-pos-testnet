#!/bin/bash

set -e

NETWORK_DIR=./network
TMUX_SESSION_NAME=ethnet

echo ""
echo "🧹 Shutdown script started"
echo "────────────────────────────────"

# 1. Kill tmux session
echo "1. Terminating tmux session..."
if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
  tmux kill-session -t "$TMUX_SESSION_NAME"
  echo "   ✅ tmux session terminated: $TMUX_SESSION_NAME"
else
  echo "   ⚠️  No tmux session found"
fi

# 2. Kill background processes
echo ""
echo "2. Stopping background processes..."

PROCESSES=("geth" "beacon-chain" "validator" "bootnode")

for i in "${!PROCESSES[@]}"; do
  name="${PROCESSES[$i]}"
  num=$((i + 1))
  if pkill "$name" > /dev/null 2>&1; then
    echo "   ✅ [$num] $name terminated"
  else
    echo "   ⚠️  [$num] $name not running"
  fi
done

echo ""
echo "✅ Shutdown complete"
echo "────────────────────────────────"
echo ""
