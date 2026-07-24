#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

swift build -c release

binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/.build/StenoTab.app"
contents_dir="$app_dir/Contents"
resources_dir="$contents_dir/Resources"
asset_info_plist="$project_dir/.build/StenoTabAssetInfo.plist"

mkdir -p "$contents_dir/MacOS" "$resources_dir"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$binary_dir/StenoTab" "$contents_dir/MacOS/StenoTab"
cp "$project_dir/Art/logo-white.svg" \
    "$resources_dir/StenoTabMenuBar.svg"

actool_path="${STENOTAB_ACTOOL_PATH:-/Applications/Xcode-beta.app/Contents/Developer/usr/bin/actool}"
if [[ ! -x "$actool_path" ]]; then
    actool_path="/Applications/Xcode.app/Contents/Developer/usr/bin/actool"
fi
if [[ ! -x "$actool_path" ]]; then
    echo "error: Xcode actool is required to compile Art/StenoTab.icon" >&2
    echo "Set STENOTAB_ACTOOL_PATH to the actool executable." >&2
    exit 1
fi

"$actool_path" "$project_dir/Art/StenoTab.icon" \
    --app-icon StenoTab \
    --compile "$resources_dir" \
    --output-partial-info-plist "$asset_info_plist" \
    --minimum-deployment-target 14.0 \
    --platform macosx \
    --target-device mac \
    --output-format human-readable-text

signing_identity="${STENOTAB_SIGNING_IDENTITY:--}"
codesign --force --deep --sign "$signing_identity" "$app_dir"

if [[ "$signing_identity" == "-" ]]; then
    echo "Warning: ad-hoc signing changes the privacy identity after every rebuild."
    echo "Set STENOTAB_SIGNING_IDENTITY to a stable Apple Development identity to preserve permissions."
fi

echo "Built $app_dir"
if [[ "${STENOTAB_NO_OPEN:-0}" == "1" ]]; then
    echo "Skipping launch because STENOTAB_NO_OPEN=1"
else
    echo "Launching app"
    open "$app_dir"
fi
