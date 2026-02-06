#!/bin/bash

# InputShare Connection Test
# Tests sender/receiver connection with timeout and diagnostics

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🧪 InputShare Connection Test"
echo "============================="
echo ""

# Check if permissions are granted first
if [ -f "./check-permissions.sh" ]; then
    echo "📋 Checking permissions first..."
    ./check-permissions.sh
    if [ $? -ne 0 ]; then
        echo ""
        echo "⚠️  Cannot run test without Accessibility permissions"
        exit 1
    fi
    echo ""
fi

echo "🚀 Step 1: Starting receiver..."
.build/arm64-apple-macosx/debug/inputshare receive \
  --port 4242 \
  --identity-p12 .certs/device-a.p12 \
  --identity-pass inputshare-dev \
  --pin-sha256 $(cat .certs/device-b.pin) \
  > /tmp/receiver-test.log 2>&1 &

RECEIVER_PID=$!
echo "   Receiver PID: $RECEIVER_PID"

# Wait for receiver to start
sleep 2

# Check if receiver is listening
if lsof -i :4242 > /dev/null 2>&1; then
    echo "   ✅ Receiver is listening on port 4242"
else
    echo "   ❌ Receiver failed to start"
    echo "   Log output:"
    cat /tmp/receiver-test.log
    kill $RECEIVER_PID 2>/dev/null
    exit 1
fi

echo ""
echo "🚀 Step 2: Starting sender (will run for 5 seconds)..."
.build/arm64-apple-macosx/debug/inputshare send \
  --host 127.0.0.1 \
  --port 4242 \
  --identity-p12 .certs/device-b.p12 \
  --identity-pass inputshare-dev \
  --pin-sha256 $(cat .certs/device-a.pin) \
  > /tmp/sender-test.log 2>&1 &

SENDER_PID=$!
echo "   Sender PID: $SENDER_PID"

# Wait a bit for connection
sleep 3

echo ""
echo "🔍 Step 3: Checking connection status..."

# Check if processes are still running
if ps -p $RECEIVER_PID > /dev/null 2>&1; then
    echo "   ✅ Receiver is running"
else
    echo "   ❌ Receiver crashed"
    echo "   Receiver log:"
    cat /tmp/receiver-test.log
fi

if ps -p $SENDER_PID > /dev/null 2>&1; then
    echo "   ✅ Sender is running"
else
    echo "   ❌ Sender crashed"
    echo "   Sender log:"
    cat /tmp/sender-test.log
fi

# Check for established connections
CONNECTIONS=$(lsof -i :4242 2>/dev/null | grep ESTABLISHED | wc -l | tr -d ' ')
if [ "$CONNECTIONS" -gt 0 ]; then
    echo "   ✅ Connection established ($CONNECTIONS active)"
    echo ""
    echo "🎉 SUCCESS! Sender and receiver are connected!"
    echo ""
    echo "   The sender is now capturing your input."
    echo "   Try moving your mouse - the receiver should inject those events."
    echo ""
else
    echo "   ⚠️  No established connection detected"
    echo ""
    echo "   This could mean:"
    echo "   - TLS handshake is in progress"
    echo "   - Certificate pinning failed"
    echo "   - Connection was rejected"
    echo ""
    echo "   Receiver log:"
    cat /tmp/receiver-test.log
    echo ""
    echo "   Sender log:"
    cat /tmp/sender-test.log
fi

echo ""
echo "🧹 Step 4: Cleaning up test processes..."
kill $SENDER_PID 2>/dev/null
kill $RECEIVER_PID 2>/dev/null
sleep 1

# Force kill if still running
kill -9 $SENDER_PID 2>/dev/null
kill -9 $RECEIVER_PID 2>/dev/null

echo "   ✅ Test complete"
echo ""
echo "📊 Test Summary:"
echo "   Logs saved to:"
echo "   - /tmp/receiver-test.log"
echo "   - /tmp/sender-test.log"
echo ""

if [ "$CONNECTIONS" -gt 0 ]; then
    echo "✅ Test PASSED - Ready for production use"
    echo ""
    echo "To run manually:"
    echo "  Terminal 1: ./run-receiver.sh"
    echo "  Terminal 2: ./run-sender.sh"
else
    echo "⚠️  Test INCOMPLETE - Review logs above"
fi
