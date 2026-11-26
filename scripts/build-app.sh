#!/bin/bash
set -euo pipefail
project="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project"
case "${1:-}" in
    ''|--universal) ;;
    *) printf '用法：%s [--universal]\n' "$0" >&2; exit 2 ;;
esac
swift build -c release
bin="$(swift build -c release --show-bin-path)"
mkdir -p dist
staging="$(mktemp -d "$project/dist/.build.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
app="$staging/WorkAndPlay.app"
mkdir -p "$app/Contents/"{MacOS,Helpers,Resources}
if [ "${1:-}" = --universal ]; then
    case "$(uname -m)" in
        arm64) other_arch=x86_64 ;;
        x86_64) other_arch=arm64 ;;
        *) printf '无法识别当前 Mac 的处理器架构。\n' >&2; exit 1 ;;
    esac
    other_target=(--triple "$other_arch-apple-macosx14.0" --scratch-path "$project/.build/release-$other_arch")
    swift build -c release "${other_target[@]}"
    other_bin="$(swift build -c release "${other_target[@]}" --show-bin-path)"
    lipo -create "$bin/WorkAndPlay" "$other_bin/WorkAndPlay" -output "$app/Contents/MacOS/WorkAndPlay"
    lipo -create "$bin/ChromeNativeHost" "$other_bin/ChromeNativeHost" -output "$app/Contents/Helpers/ChromeNativeHost"
else
    cp "$bin/WorkAndPlay" "$app/Contents/MacOS/"
    cp "$bin/ChromeNativeHost" "$app/Contents/Helpers/"
fi
cp "$app/Contents/Helpers/ChromeNativeHost" "$app/Contents/Helpers/EdgeNativeHost"
swift "$project/scripts/make-icon.swift" "$staging/WorkAndPlay.iconset"
iconutil --convert icns --output "$app/Contents/Resources/WorkAndPlay.icns" "$staging/WorkAndPlay.iconset"
ditto "$project/chrome-extension" "$app/Contents/Resources/chrome-extension"
ditto "$project/Assets" "$app/Contents/Resources/MetricStickers"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>工时簿</string>
    <key>CFBundleName</key><string>工时簿</string>
    <key>CFBundleExecutable</key><string>WorkAndPlay</string>
    <key>CFBundleIdentifier</key><string>local.workandplay</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.3</string>
    <key>CFBundleVersion</key><string>13</string>
    <key>CFBundleIconFile</key><string>WorkAndPlay.icns</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app/Contents/Helpers/ChromeNativeHost"
codesign --force --sign - "$app/Contents/Helpers/EdgeNativeHost"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
rm -rf -- "$project/dist/WorkAndPlay.app"
mv -- "$app" "$project/dist/WorkAndPlay.app"
printf '%s\n' "$project/dist/WorkAndPlay.app"
