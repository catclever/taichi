#!/bin/bash

APP_NAME="TaiChi"
APP_BUNDLE="$APP_NAME.app"
BIN_PATH=".build/debug/$APP_NAME"

echo "Building Swift package..."
swift build

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

echo "Creating app bundle at $APP_BUNDLE..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/"

# Generate and build AppIcon.icns
echo "Generating AppIcon..."
if [ -f "generate_icon.swift" ]; then
    swift generate_icon.swift
    if [ -f "AppIcon.png" ]; then
        mkdir -p AppIcon.iconset
        sips -z 16 16     AppIcon.png --out AppIcon.iconset/icon_16x16.png > /dev/null
        sips -z 32 32     AppIcon.png --out AppIcon.iconset/icon_16x16@2x.png > /dev/null
        sips -z 32 32     AppIcon.png --out AppIcon.iconset/icon_32x32.png > /dev/null
        sips -z 64 64     AppIcon.png --out AppIcon.iconset/icon_32x32@2x.png > /dev/null
        sips -z 128 128   AppIcon.png --out AppIcon.iconset/icon_128x128.png > /dev/null
        sips -z 256 256   AppIcon.png --out AppIcon.iconset/icon_128x128@2x.png > /dev/null
        sips -z 256 256   AppIcon.png --out AppIcon.iconset/icon_256x256.png > /dev/null
        sips -z 512 512   AppIcon.png --out AppIcon.iconset/icon_256x256@2x.png > /dev/null
        sips -z 512 512   AppIcon.png --out AppIcon.iconset/icon_512x512.png > /dev/null
        sips -z 1024 1024 AppIcon.png --out AppIcon.iconset/icon_512x512@2x.png > /dev/null
        iconutil -c icns AppIcon.iconset -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
        rm -rf AppIcon.iconset AppIcon.png
    fi
fi

# Create basic Info.plist
cat <<EOF > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.kael.taichi</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>太极需要此权限来跨桌面唤醒窗口</string>
</dict>
</plist>
EOF

echo "Done! You can now run the app using: open $APP_BUNDLE"
