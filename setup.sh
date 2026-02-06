#!/bin/bash
set -e

# InputShare Development Setup Script
# Generates TLS certificates for local testing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/.certs"
P12_PASSWORD="inputshare-dev"

echo "🔧 InputShare Development Setup"
echo "================================"
echo ""

# Check for required tools
if ! command -v openssl &> /dev/null; then
    echo "❌ Error: openssl is required but not installed"
    exit 1
fi

if ! command -v swift &> /dev/null; then
    echo "❌ Error: swift is required but not installed"
    exit 1
fi

# Clean up old certificates
if [ -d "$CERTS_DIR" ]; then
    echo "🗑️  Removing old certificates..."
    rm -rf "$CERTS_DIR"
fi

mkdir -p "$CERTS_DIR"
cd "$CERTS_DIR"

echo "📜 Step 1: Generating Certificate Authority..."
openssl genrsa -out inputshare-dev-ca.key 4096 2>/dev/null
openssl req -x509 -new -nodes -key inputshare-dev-ca.key -sha256 -days 3650 \
    -out inputshare-dev-ca.crt \
    -subj "/CN=InputShare Dev CA" 2>/dev/null
echo "   ✅ CA created"

# Function to generate device certificate
generate_device_cert() {
    local device_name=$1
    local cn="InputShare Device $device_name"

    echo ""
    echo "🔐 Step 2: Generating certificate for $device_name..."

    # Generate private key
    openssl genrsa -out "device-$device_name.key" 2048 2>/dev/null

    # Generate CSR
    openssl req -new -key "device-$device_name.key" \
        -out "device-$device_name.csr" \
        -subj "/CN=$cn" 2>/dev/null

    # Sign certificate
    openssl x509 -req -in "device-$device_name.csr" \
        -CA inputshare-dev-ca.crt \
        -CAkey inputshare-dev-ca.key \
        -CAcreateserial \
        -out "device-$device_name.crt" \
        -days 825 -sha256 2>/dev/null

    # Export as PKCS#12
    openssl pkcs12 -export \
        -inkey "device-$device_name.key" \
        -in "device-$device_name.crt" \
        -certfile inputshare-dev-ca.crt \
        -out "device-$device_name.p12" \
        -password "pass:$P12_PASSWORD" 2>/dev/null

    # Compute SHA-256 pin
    local pin=$(openssl x509 -in "device-$device_name.crt" -outform der | shasum -a 256 | awk '{print $1}')

    echo "   ✅ Certificate created: device-$device_name.p12"
    echo "   🔑 PIN (SHA-256): $pin"

    # Store pin for later use
    echo "$pin" > "device-$device_name.pin"
}

# Generate certificates for two devices
generate_device_cert "a"
generate_device_cert "b"

echo ""
echo "🏗️  Step 3: Building project..."
cd "$SCRIPT_DIR"
swift build --quiet

echo ""
echo "✅ Setup complete!"
echo ""
echo "📋 Certificate Information:"
echo "   Location: $CERTS_DIR"
echo "   Password: $P12_PASSWORD"
echo ""
echo "🚀 Quick Start:"
echo ""
echo "   Terminal 1 (Receiver - Device A):"
echo "   ----------------------------------"
PIN_A=$(cat "$CERTS_DIR/device-a.pin")
PIN_B=$(cat "$CERTS_DIR/device-b.pin")
echo "   swift run inputshare receive \\"
echo "     --port 4242 \\"
echo "     --identity-p12 .certs/device-a.p12 \\"
echo "     --identity-pass $P12_PASSWORD \\"
echo "     --pin-sha256 $PIN_B"
echo ""
echo "   Terminal 2 (Sender - Device B):"
echo "   --------------------------------"
echo "   swift run inputshare send \\"
echo "     --host 127.0.0.1 \\"
echo "     --port 4242 \\"
echo "     --identity-p12 .certs/device-b.p12 \\"
echo "     --identity-pass $P12_PASSWORD \\"
echo "     --pin-sha256 $PIN_A"
echo ""
echo "⚠️  Note: You'll be prompted for Accessibility permissions on first run"
echo ""

# Create convenience run scripts
cat > "$SCRIPT_DIR/run-receiver.sh" <<EOF
#!/bin/bash
cd "$SCRIPT_DIR"
swift run inputshare receive \\
  --port 4242 \\
  --identity-p12 .certs/device-a.p12 \\
  --identity-pass $P12_PASSWORD \\
  --pin-sha256 $PIN_B
EOF
chmod +x "$SCRIPT_DIR/run-receiver.sh"

cat > "$SCRIPT_DIR/run-sender.sh" <<EOF
#!/bin/bash
cd "$SCRIPT_DIR"
swift run inputshare send \\
  --host 127.0.0.1 \\
  --port 4242 \\
  --identity-p12 .certs/device-b.p12 \\
  --identity-pass $P12_PASSWORD \\
  --pin-sha256 $PIN_A
EOF
chmod +x "$SCRIPT_DIR/run-sender.sh"

echo "💡 Convenience scripts created:"
echo "   ./run-receiver.sh - Start receiver (Device A)"
echo "   ./run-sender.sh   - Start sender (Device B)"
echo ""
