#!/bin/bash
# GitSync Build Script
# Sets up environment and runs Flutter build commands

# ============================================
# CUSTOMIZE THESE PATHS FOR YOUR SYSTEM
# ============================================

FLUTTER_HOME=${FLUTTER_HOME:-"/home/slips/src/flutter"}  # e.g., ~/flutter, /opt/flutter, /home/user/src/flutter
ANDROID_HOME=${ANDROID_HOME:-"/home/slips/src/android-sdk"}   # e.g., ~/Android/Sdk, /opt/android-sdk

# ============================================
# AUTO-DETECTION (optional - uncomment if needed)
# ============================================

# Uncomment these lines to auto-detect common Flutter/Android SDK locations:
# if [ -z "$FLUTTER_HOME" ] && [ -d "$HOME/flutter" ]; then
#     FLUTTER_HOME="$HOME/flutter"
# fi
#
# if [ -z "$ANDROID_HOME" ] && [ -d "$HOME/Android/Sdk" ]; then
#     ANDROID_HOME="$HOME/Android/Sdk"
# fi

# ============================================
# ENVIRONMENT SETUP
# ============================================

# Add Flutter to PATH
if [ -n "$FLUTTER_HOME" ]; then
    export PATH="$FLUTTER_HOME/bin:$PATH"
fi

# Set Android SDK environment variables
if [ -n "$ANDROID_HOME" ]; then
    export ANDROID_HOME="$ANDROID_HOME"
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
fi

# ============================================
# VALIDATION
# ============================================

# Check Flutter is available
if ! command -v flutter &> /dev/null; then
    echo "Error: Flutter not found in PATH"
    echo ""
    echo "Please set FLUTTER_HOME in this script or add Flutter to your PATH"
    echo "Current FLUTTER_HOME: ${FLUTTER_HOME:-'(not set)'}"
    echo ""
    echo "Usage: ./build.sh <command>"
    echo "Commands: pub get, build apk --debug, analyze, clean"
    exit 1
fi

# Warn if Android SDK is not configured
if [ -z "$ANDROID_HOME" ] && [ -z "$ANDROID_SDK_ROOT" ]; then
    echo "Warning: ANDROID_HOME is not set. Android builds may fail."
    echo "Set ANDROID_HOME in this script or ensure it's in your environment."
    echo ""
fi

# ============================================
# HELPER FUNCTIONS
# ============================================

# Get git branch name
get_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
}

# Get timestamp in format YYYYMMDD-HHMMSS
get_timestamp() {
    date +%Y%m%d-%H%M%S
}

# Build debug APK with branch name and timestamp in output filename
build-debug-timestamped() {
    local branch=$(get_branch | tr '/' '-')
    local timestamp=$(get_timestamp)
    local default_output="build/app/outputs/flutter-apk/app-debug.apk"
    local timestamped_output="build/app/outputs/flutter-apk/app-debug-${branch}-${timestamp}.apk"
    
    echo "Building debug APK..."
    echo "  Branch: $branch"
    echo "  Timestamp: $timestamp"
    echo "  Target: $timestamped_output"
    
    # Build to default location
    flutter build apk --debug
    
    if [ -f "$default_output" ]; then
        # Copy with branch+timestamp name
        cp "$default_output" "$timestamped_output"
        echo ""
        echo "Build complete!"
        echo "  Output: $timestamped_output"
        ls -lh "$timestamped_output"
    else
        echo "Error: Build failed - output file not found"
        exit 1
    fi
}

# ============================================
# COMMAND HANDLING
# ============================================

# Handle special commands
case "$1" in
    build-debug-timestamped)
        build-debug-timestamped
        exit $?
        ;;
    "")
        echo "Usage: ./build.sh <command>"
        echo ""
        echo "Commands:"
        echo "  pub get                    Install dependencies"
        echo "  build apk --debug          Build debug APK"
        echo "  build-debug-timestamped    Build debug APK with branch+timestamp in filename"
        echo "  analyze                   Run linter"
        echo "  clean                     Clean build artifacts"
        echo ""
        echo "Examples:"
        echo "  ./build.sh pub get"
        echo "  ./build.sh build apk --debug"
        echo "  ./build.sh build-debug-timestamped"
        echo "  ./build.sh analyze"
        echo "  ./build.sh clean"
        exit 0
        ;;
esac

# ============================================
# RUN FLUTTER
# ============================================

flutter "$@"
