#!/bin/zsh
set -euo pipefail

action="${1:-list}"
profile_id="${2:-gemma-4-e2b-it}"
port="${TAB_COMPLETION_LOCAL_PORT:-8080}"

profile() {
    case "$1" in
        gemma-3-270m-base)
            repo="mlx-community/gemma-3-270m-4bit"
            api_style="textCompletions"
            label="Gemma 3 270M Base · Experimental"
            ;;
        gemma-3-1b-base)
            repo="mlx-community/gemma-3-1b-pt-4bit"
            api_style="textCompletions"
            label="Gemma 3 1B Base · Fast · 8 GB"
            ;;
        gemma-3-1b-it)
            repo="mlx-community/gemma-3-1b-it-4bit"
            api_style="chatCompletions"
            label="Gemma 3 1B IT · Promptable · 8 GB"
            ;;
        gemma-4-e2b-base)
            repo="mlx-community/gemma-4-e2b-4bit"
            api_style="textCompletions"
            label="Gemma 4 E2B Base · Quality Continuation · 16 GB"
            ;;
        gemma-4-e2b-it)
            repo="mlx-community/gemma-4-e2b-it-4bit"
            api_style="gemmaChatPrefill"
            label="Gemma 4 E2B IT · Assistant Prefill · 16 GB"
            ;;
        *)
            print -u2 "Unknown profile: $1"
            exit 2
            ;;
    esac
}

list_profiles() {
    for candidate in \
        gemma-3-270m-base \
        gemma-3-1b-base \
        gemma-3-1b-it \
        gemma-4-e2b-base \
        gemma-4-e2b-it
    do
        profile "$candidate"
        print "$candidate\t$label\t$repo"
    done
}

write_configuration() {
    profile "$profile_id"
    config_dir="${HOME}/Library/Application Support/Tab Completions Everywhere"
    config_path="$config_dir/local-model.json"
    mkdir -p "$config_dir"
    printf '%s\n' \
        "{\"profileID\":\"$profile_id\",\"baseURL\":\"http://127.0.0.1:$port/v1\",\"maximumWords\":8}" \
        > "$config_path"
    print "Configured TCE to use $label"
    print "Configuration: $config_path"
    print "Weights: shared Hugging Face cache (no app-owned copy)"
}

serve() {
    profile "$profile_id"
    if ! command -v mlx_lm.server >/dev/null 2>&1; then
        print -u2 "mlx_lm.server was not found. Install it with: brew install mlx-lm"
        exit 1
    fi

    arguments=(
        --model "$repo"
        --host 127.0.0.1
        --port "$port"
        --max-tokens 16
        --temp 0
        --prompt-cache-size 8
    )
    if [[ "$api_style" != "textCompletions" ]]; then
        arguments+=(--chat-template-args '{"enable_thinking":false}')
    fi

    print "Starting $label"
    print "Repository: $repo"
    print "Hugging Face will reuse its standard cache."
    exec mlx_lm.server "${arguments[@]}"
}

case "$action" in
    list)
        list_profiles
        ;;
    configure)
        write_configuration
        ;;
    serve)
        serve
        ;;
    use)
        write_configuration
        serve
        ;;
    benchmark)
        profile "$profile_id"
        script_dir="${0:A:h}"
        exec /usr/bin/python3 "$script_dir/benchmark-local-model.py" \
            --url "http://127.0.0.1:$port/v1" \
            --model "$repo" \
            --api-style "$api_style"
        ;;
    *)
        print -u2 "Usage: $0 {list|configure|serve|use|benchmark} [profile]"
        exit 2
        ;;
esac
