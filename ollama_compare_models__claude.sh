#!/bin/bash

PROMPT_FILE="$HOME/Downloads/prompt.txt"
CSV_FILE="$HOME/Downloads/model_comparison.csv"
OUTPUT_DIR="$HOME/Downloads"
HOST=$(hostname)

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "ERROR: Prompt file not found: $PROMPT_FILE"
    exit 1
fi

echo "Prompt file : $PROMPT_FILE"
echo "Output CSV  : $CSV_FILE"
echo "Host        : $HOST"
echo ""

# Write header only when starting fresh
if [[ ! -f "$CSV_FILE" ]]; then
    printf 'host,model,total duration (s),load duration (ms),prompt eval count (tokens),prompt eval duration (ms),prompt eval rate (tokens/s),eval count (tokens),eval duration (s),eval rate (tokens/s)\n' \
        > "$CSV_FILE"
    echo "Created CSV with header."
fi

# ---------------------------------------------------------------------------
# Duration conversion helpers
# ---------------------------------------------------------------------------

# Accepts strings like 18.45s, 1m18.45s → outputs decimal seconds
to_seconds() {
    local val="$1"
    if [[ "$val" =~ ^([0-9]+)m([0-9.]+)s$ ]]; then
        echo "$(echo "${BASH_REMATCH[1]} * 60 + ${BASH_REMATCH[2]}" | bc)"
    elif [[ "$val" =~ ^([0-9.]+)s$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$val" =~ ^([0-9.]+)ms$ ]]; then
        # sub-second load times sometimes appear as total duration
        echo "$(echo "scale=6; ${BASH_REMATCH[1]} / 1000" | bc)"
    else
        echo "$val"
    fi
}

# Accepts strings like 79.72ms, 1.2s, 450µs / 450us → outputs decimal ms
to_ms() {
    local val="$1"
    if [[ "$val" =~ ^([0-9.]+)ms$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$val" =~ ^([0-9.]+)s$ ]]; then
        echo "$(echo "scale=3; ${BASH_REMATCH[1]} * 1000" | bc)"
    elif [[ "$val" =~ ^([0-9.]+)(µs|us)$ ]]; then
        echo "$(echo "scale=6; ${BASH_REMATCH[1]} / 1000" | bc)"
    else
        echo "$val"
    fi
}

# ---------------------------------------------------------------------------
# Stop any loaded models and verify
# ---------------------------------------------------------------------------
stop_all_models() {
    local running
    running=$(ollama ps 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v '^$' || true)

    if [[ -z "$running" ]]; then
        echo "  No model currently loaded."
        return 0
    fi

    echo "  Stopping loaded model(s)..."
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        echo "  -> ollama stop $m"
        ollama stop "$m" 2>/dev/null || true
    done <<< "$running"

    sleep 2

    # Verify
    running=$(ollama ps 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v '^$' || true)
    if [[ -n "$running" ]]; then
        echo "  WARNING: models still loaded after stop: $running"
        return 1
    fi
    echo "  All models unloaded."
    return 0
}

# ---------------------------------------------------------------------------
# Parse a single stat line from the output file
#   $1 = output file
#   $2 = grep pattern
#   $3 = (optional) grep -v pattern to exclude
#   $4 = awk field index for the value
# ---------------------------------------------------------------------------
parse_stat() {
    local file="$1" pattern="$2" exclude="$3" field="$4"
    if [[ -n "$exclude" ]]; then
        grep "$pattern" "$file" 2>/dev/null | grep -v "$exclude" | tail -1 | awk "{print \$$field}"
    else
        grep "$pattern" "$file" 2>/dev/null | tail -1 | awk "{print \$$field}"
    fi
}

# ---------------------------------------------------------------------------
# Discover models
# ---------------------------------------------------------------------------
MODELS=()
while IFS= read -r line; do
    MODELS+=("$line")
done < <(ollama list | tail -n +2 | awk '{print $1}' | grep -v '^$')

if [[ ${#MODELS[@]} -eq 0 ]]; then
    echo "No models found via 'ollama list'. Exiting."
    exit 1
fi

echo "Models to benchmark: ${#MODELS[@]}"
for m in "${MODELS[@]}"; do echo "  - $m"; done
echo ""

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
for model in "${MODELS[@]}"; do
    echo "============================================================"
    echo "Model: $model"
    echo "============================================================"

    # Ensure clean state before running
    stop_all_models

    # Build a filesystem-safe output filename
    safe_name=$(echo "$model" | tr '/: ' '___' | tr -d '()[]')
    output_file="$OUTPUT_DIR/${safe_name}_output.txt"

    echo "  Running: ollama run --verbose $model"
    echo "  Output : $output_file"

    # Run model; verbose stats go to stderr — merge into output file
    if ollama run --verbose "$model" < "$PROMPT_FILE" > "$output_file" 2>&1; then
        echo "  Run completed."
    else
        echo "  WARNING: ollama run exited non-zero for $model. Continuing..."
    fi

    # ---- Parse stats -------------------------------------------------------
    total_dur_raw=$(parse_stat  "$output_file" "total duration:"       ""       3)
    load_dur_raw=$(parse_stat   "$output_file" "load duration:"        ""       3)
    p_eval_cnt=$(parse_stat     "$output_file" "prompt eval count:"    ""       4)
    p_eval_dur_raw=$(parse_stat "$output_file" "prompt eval duration:" ""       4)
    p_eval_rate=$(parse_stat    "$output_file" "prompt eval rate:"     ""       4)
    eval_cnt=$(parse_stat       "$output_file" "eval count:"    "prompt"        3)
    eval_dur_raw=$(parse_stat   "$output_file" "eval duration:" "prompt"        3)
    eval_rate=$(parse_stat      "$output_file" "eval rate:"     "prompt"        3)

    # Convert to requested units
    total_dur_s=$(to_seconds "$total_dur_raw")
    load_dur_ms=$(to_ms      "$load_dur_raw")
    p_eval_dur_ms=$(to_ms    "$p_eval_dur_raw")
    eval_dur_s=$(to_seconds  "$eval_dur_raw")

    echo "  Stats:"
    echo "    total duration:       ${total_dur_s}s"
    echo "    load duration:        ${load_dur_ms}ms"
    echo "    prompt eval count:    ${p_eval_cnt} tokens"
    echo "    prompt eval duration: ${p_eval_dur_ms}ms"
    echo "    prompt eval rate:     ${p_eval_rate} tokens/s"
    echo "    eval count:           ${eval_cnt} tokens"
    echo "    eval duration:        ${eval_dur_s}s"
    echo "    eval rate:            ${eval_rate} tokens/s"

    # ---- Append to CSV -----------------------------------------------------
    printf '"%s","%s",%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$HOST" \
        "$model" \
        "${total_dur_s:-NA}" \
        "${load_dur_ms:-NA}" \
        "${p_eval_cnt:-NA}" \
        "${p_eval_dur_ms:-NA}" \
        "${p_eval_rate:-NA}" \
        "${eval_cnt:-NA}" \
        "${eval_dur_s:-NA}" \
        "${eval_rate:-NA}" \
        >> "$CSV_FILE"

    echo "  Appended to CSV."
    echo ""
done

echo "============================================================"
echo "All models benchmarked."
echo "CSV: $CSV_FILE"
echo "============================================================"
cat "$CSV_FILE"
