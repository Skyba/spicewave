#!/bin/sh
# Builds and installs ~/Applications/Butterchurn.app
set -eu
cd "$(dirname "$0")"
APP="$HOME/Applications/Butterchurn.app"
rm -rf build && mkdir -p build/Butterchurn.app/Contents/MacOS build/Butterchurn.app/Contents/Resources
swiftc -O -swift-version 5 -target arm64-apple-macosx14.4 main.swift -o build/Butterchurn.app/Contents/MacOS/Butterchurn
cp Info.plist build/Butterchurn.app/Contents/
cp -R web build/Butterchurn.app/Contents/Resources/
codesign --force --sign - build/Butterchurn.app
rm -rf "$APP" && cp -R build/Butterchurn.app "$APP"
echo "Installed $APP"
