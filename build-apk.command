#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f android/app/src/main/cpp/lzfse/src/lzfse.h ]; then
    if [ -d .git ] && command -v git >/dev/null 2>&1; then
        git submodule update --init --recursive
    else
        echo "The LZFSE submodule is missing. Clone this repository using:"
        echo "git clone --recurse-submodules https://github.com/nikolaign/sito-ios.git"
        exit 1
    fi
fi

if ! command -v gradle >/dev/null 2>&1; then
    echo "Gradle is missing. Install Android Studio and Gradle 8.13 first."
    echo "Use Gradle 8.13 (the version used by this project's GitHub Actions)."
    exit 1
fi

echo "Building SITO for Android…"
gradle -p android :app:assembleDebug --no-daemon

mkdir -p build
cp android/app/build/outputs/apk/debug/app-debug.apk build/SITO-0.9.5-android-debug.apk
echo ""
echo "Android APK ready: $(pwd)/build/SITO-0.9.5-android-debug.apk"
echo "This is a debug-signed APK for testing."
