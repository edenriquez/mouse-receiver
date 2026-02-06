#!/bin/bash

# Rebuild InputShare for current architecture

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ARCH=$(uname -m)

echo "🔧 Rebuilding InputShare"
echo "======================="
echo ""
echo "System architecture: $ARCH"
echo ""

# Clean build
echo "🧹 Cleaning previous build..."
rm -rf .build
echo "   ✅ Clean complete"
echo ""

# Build for current architecture
echo "🏗️  Building for $ARCH..."
if [ "$ARCH" = "arm64" ]; then
    swift build --arch arm64
elif [ "$ARCH" = "x86_64" ]; then
    swift build --arch x86_64
else
    echo "⚠️  Unknown architecture, attempting default build..."
    swift build
fi

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Build successful!"
    echo ""

    # Find the built binary
    BINARY=$(find .build -name "inputshare" -type f -perm +111 | head -1)
    if [ -n "$BINARY" ]; then
        BINARY_ARCH=$(file "$BINARY" | grep -o 'arm64\|x86_64' | head -1)
        echo "📦 Binary location: $BINARY"
        echo "🏗️  Binary architecture: $BINARY_ARCH"
        echo ""

        if [ "$ARCH" = "$BINARY_ARCH" ]; then
            echo "✅ Architecture matches! Ready to run."
        else
            echo "⚠️  Architecture mismatch - may have issues running"
        fi
    fi
else
    echo ""
    echo "❌ Build failed"
    exit 1
fi
