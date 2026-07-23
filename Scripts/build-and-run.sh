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
codesign --force --deep --sign - "$app_dir"

echo "Built $app_dir"
if [[ "${TAB_COMPLETION_NO_OPEN:-0}" == "1" ]]; then
    echo "Skipping launch because TAB_COMPLETION_NO_OPEN=1"
else
    echo "Launching app"
    open "$app_dir"
fi
