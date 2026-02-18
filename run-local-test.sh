#!/bin/bash
set -e

echo "=== Mouse Sharing Local Test ==="
echo ""
echo "Building..."
swift build 2>&1 | tail -5

BINARY=".build/debug/inputshare"
PORT=4242

echo ""
echo "Starting mock receiver on port $PORT..."
$BINARY mock-receive --port $PORT &
RECEIVER_PID=$!

sleep 1

echo "Starting sender connecting to localhost:$PORT..."
echo ""
echo "=== INSTRUCTIONS ==="
echo "Move your mouse to the TOP-RIGHT corner of your screen."
echo "Hold it there for ~0.15 seconds."
echo "You should see JSON events printed below from the mock receiver."
echo "Press Ctrl+C to stop."
echo "===================="
echo ""

$BINARY send --host 127.0.0.1 --port $PORT &
SENDER_PID=$!

cleanup() {
    echo ""
    echo "Stopping..."
    kill $RECEIVER_PID 2>/dev/null || true
    kill $SENDER_PID 2>/dev/null || true
    wait $RECEIVER_PID 2>/dev/null || true
    wait $SENDER_PID 2>/dev/null || true
    echo "Done."
}

trap cleanup EXIT INT TERM
wait
