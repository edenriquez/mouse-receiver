#!/bin/bash

# InputShare Permission Checker
# Verifies Accessibility permissions before running sender/receiver

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🔍 InputShare Permission Checker"
echo "================================"
echo ""

# Build a simple permission checker
cat > /tmp/check_accessibility.swift <<'EOF'
import Foundation
import ApplicationServices

let isTrusted = AXIsProcessTrusted()
if isTrusted {
    print("GRANTED")
} else {
    print("DENIED")
}
EOF

echo "📋 Step 1: Compiling permission checker..."
swiftc /tmp/check_accessibility.swift -o /tmp/check_accessibility 2>/dev/null

if [ $? -ne 0 ]; then
    echo "❌ Failed to compile checker"
    exit 1
fi

echo "🔐 Step 2: Checking Accessibility permissions..."
RESULT=$(/tmp/check_accessibility)

if [ "$RESULT" = "GRANTED" ]; then
    echo "✅ Accessibility permissions are GRANTED"
    echo ""
    echo "🎉 You're ready to run InputShare!"
    echo ""
    echo "Next steps:"
    echo "  1. Terminal 1: ./run-receiver.sh"
    echo "  2. Terminal 2: ./run-sender.sh"
    echo ""
    exit 0
else
    echo "❌ Accessibility permissions are NOT GRANTED"
    echo ""
    echo "📖 How to grant permissions:"
    echo ""
    echo "  1. Open System Settings"
    echo "  2. Go to: Privacy & Security → Accessibility"
    echo "  3. Click the lock icon to make changes"
    echo "  4. Look for your terminal app in the list:"
    echo "     - Terminal.app"
    echo "     - iTerm2"
    echo "     - or other terminal apps"
    echo "  5. Toggle it ON (checkmark should appear)"
    echo "  6. Run this script again to verify"
    echo ""
    echo "💡 Tip: You may need to trigger the permission prompt first."
    echo "   Running this will show the system prompt:"
    echo ""
    echo "   swift run inputshare send --host 127.0.0.1 --port 4242 \\"
    echo "     --identity-p12 .certs/device-b.p12 \\"
    echo "     --identity-pass inputshare-dev \\"
    echo "     --pin-sha256 dummy"
    echo ""
    echo "   (Press Ctrl+C after seeing the prompt)"
    echo ""
    exit 1
fi
