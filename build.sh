#!/bin/sh
# Builds and installs ~/Applications/Spicewave.app
set -eu
cd "$(dirname "$0")"
APP="$HOME/Applications/Spicewave.app"
rm -rf build && mkdir -p build/Spicewave.app/Contents/MacOS build/Spicewave.app/Contents/Resources
swiftc -O -swift-version 5 -target arm64-apple-macosx14.4 main.swift -o build/Spicewave.app/Contents/MacOS/Spicewave
cp Info.plist build/Spicewave.app/Contents/
cp -R web build/Spicewave.app/Contents/Resources/
codesign --force --sign - build/Spicewave.app
rm -rf "$APP" && cp -R build/Spicewave.app "$APP"
echo "Installed $APP"
