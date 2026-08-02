#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
output_path="${1:-$repo_dir/releases/Coze-2.2-macOS.zip}"
build_dir="$(mktemp -d)"
trap '/bin/rm -rf "$build_dir"' EXIT

app_path="$build_dir/Coze.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"

frameworks=(-framework Cocoa -framework ApplicationServices -framework UserNotifications)
swiftc -parse-as-library -target arm64-apple-macos12.0 "$repo_dir/macos/Coze.swift" -o "$build_dir/Coze-arm64" "${frameworks[@]}"
swiftc -parse-as-library -target x86_64-apple-macos12.0 "$repo_dir/macos/Coze.swift" -o "$build_dir/Coze-x86_64" "${frameworks[@]}"
lipo -create "$build_dir/Coze-arm64" "$build_dir/Coze-x86_64" -output "$app_path/Contents/MacOS/Coze"

cp "$repo_dir/macos/Info.plist" "$app_path/Contents/Info.plist"
cp "$repo_dir/macos/Coze.icns" "$app_path/Contents/Resources/Coze.icns"
codesign --force --deep --sign - "$app_path"

mkdir -p "${output_path:h}"
archive_path="$build_dir/${output_path:t}"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
mv "$archive_path" "$output_path"

file "$app_path/Contents/MacOS/Coze"
lipo -info "$app_path/Contents/MacOS/Coze"
codesign --verify --deep --strict --verbose=2 "$app_path"
print "Built $output_path"
