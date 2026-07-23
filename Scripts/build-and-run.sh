#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

swift build -c release

binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/.build/Tab Completions Everywhere.app"
contents_dir="$app_dir/Contents"

mkdir -p "$contents_dir/MacOS"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$binary_dir/TabCompletionsEverywhere" "$contents_dir/MacOS/TabCompletionsEverywhere"
signing_identity="${TAB_COMPLETION_SIGNING_IDENTITY:--}"
codesign --force --deep --sign "$signing_identity" "$app_dir"

if [[ "$signing_identity" == "-" ]]; then
    echo "Warning: ad-hoc signing changes the privacy identity after every rebuild."
    echo "Set TAB_COMPLETION_SIGNING_IDENTITY to a stable Apple Development identity to preserve permissions."
fi

echo "Built $app_dir"
if [[ "${TAB_COMPLETION_NO_OPEN:-0}" == "1" ]]; then
    echo "Skipping launch because TAB_COMPLETION_NO_OPEN=1"
else
    echo "Launching app"
    open "$app_dir"
fi
