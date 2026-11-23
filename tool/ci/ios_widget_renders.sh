#!/bin/bash
# The iOS widgets in ios/WriteNoteWidget, every size in light and dark, and
# a recording's Live Activity, rendered on an iPhone simulator to
# build/widget-renders/ios for a reviewer to hold against the Widgets · v2
# boards and "Recording away from the app":
#
#   bash tool/ci/ios_widget_renders.sh <booted simulator udid>
#
# There's no Xcode project or Flutter build involved: swiftc compiles the
# widgets' own views with tool/ci/WidgetRenders.swift into a bare app bundle,
# next to the extension's glyphs, compiled by actool, and its fonts. The
# simulator runs that, and it fails if a glyph, a font or a link is off.
set -euo pipefail

udid=$1
widget=ios/WriteNoteWidget
work=build/widget-renders
app=$work/WidgetRenders.app
rm -rf "$work"
mkdir -p "$app" "$work/ios"

xcrun --sdk iphonesimulator swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-ios17.0-simulator" -module-name WidgetRenders \
  "$widget/QuickAction.swift" "$widget/WriteNoteWidget.swift" \
  "$widget/QuickActionsWidget.swift" "$widget/RecordingAttributes.swift" \
  "$widget/RecordingLiveActivity.swift" tool/ci/WidgetRenders.swift \
  -o "$app/WidgetRenders"
xcrun actool "$widget/Assets.xcassets" --compile "$app" \
  --platform iphonesimulator --minimum-deployment-target 17.0 \
  --target-device iphone --output-partial-info-plist "$work/assets.plist" \
  --errors --warnings --output-format human-readable-text
cp "$widget"/*.ttf "$app/"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>WidgetRenders</string>
	<key>CFBundleIdentifier</key>
	<string>com.kapybara.kapynotes.widget-renders</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
</dict>
</plist>
PLIST

xcrun simctl bootstatus "$udid" -b
xcrun simctl spawn "$udid" "$PWD/$app/WidgetRenders" "$PWD/$work/ios" "$PWD/$widget/Info.plist"
