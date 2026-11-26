#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=SystemSoundPan.app
rm -rf $APP; mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp AppIcon.icns $APP/Contents/Resources/
swiftc -O main.swift -o $APP/Contents/MacOS/SystemSoundPan
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.systemsoundpan</string>
<key>CFBundleName</key><string>SystemSoundPan</string>
<key>CFBundleExecutable</key><string>SystemSoundPan</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>システム音をウィンドウ位置に応じて左右にパンするために、システムサウンドの音声を取得します。</string>
</dict></plist>
PL
codesign --force --sign - $APP
echo built $APP
