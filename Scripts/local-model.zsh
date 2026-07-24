#!/bin/zsh
set -euo pipefail

action="${1:-list}"
profile_id="${2:-gemma-4-e2b-base}"
port="${STENOTAB_LOCAL_PORT:-18473}"
script_dir="${0:A:h}"

profile() {
    case "$1" in
        gemma-4-e2b-base)
            repo="mradermacher/gemma-4-E2B-GGUF"
            model_file="gemma-4-E2B.Q4_K_M.gguf"
            model_id="stenotab/gemma-4-e2b-base"
            api_style="textCompletions"
            label="Gemma 4 E2B Base Q4_K_M · Recommended · 16 GB"
            ;;
        *)
            print -u2 "Unknown profile: $1"
            exit 2
            ;;
    esac
}

list_profiles() {
    profile gemma-4-e2b-base
    print "gemma-4-e2b-base\t$label\t$repo\t$model_file"
}

download_model() {
    profile "$profile_id"
    if ! command -v hf >/dev/null 2>&1; then
        print -u2 "The Hugging Face CLI was not found."
        print -u2 "Install it with: brew install hf"
        exit 1
    fi
    print "Downloading $label into the shared Hugging Face cache."
    hf download "$repo" "$model_file"
}

write_configuration() {
    profile "$profile_id"
    config_dir="${HOME}/Library/Application Support/StenoTab"
    config_path="$config_dir/local-model.json"
    mkdir -p "$config_dir"
    printf '%s\n' \
        "{\"profileID\":\"$profile_id\",\"baseURL\":\"http://127.0.0.1:$port/v1\",\"maximumWords\":8}" \
        > "$config_path"
    print "Configured StenoTab to use $label"
    print "Configuration: $config_path"
    print "Weights: shared Hugging Face cache (no app-owned copy)"
    if ! command -v llama-server >/dev/null 2>&1; then
        print -u2 "llama-server was not found."
        print -u2 "Install it with: brew install llama.cpp"
        exit 1
    fi
    print "Restart StenoTab. The app will launch and own llama-server."
}

case "$action" in
    list)
        list_profiles
        ;;
    download)
        download_model
        ;;
    configure)
        download_model
        write_configuration
        ;;
    benchmark)
        profile "$profile_id"
        exec /usr/bin/python3 "$script_dir/benchmark-local-model.py" \
            --url "http://127.0.0.1:$port/v1" \
            --model "$model_id" \
            --api-style "$api_style"
        ;;
    *)
        print -u2 "Usage: $0 {list|download|configure|benchmark} [profile]"
        exit 2
        ;;
esac
