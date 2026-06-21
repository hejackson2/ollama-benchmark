#!/bin/bash

# Ensure script is run from the directory where it is located
cd "$(dirname "$0")"

PROMPT_FILE="prompt.txt"
CSV_FILE="model_comparison.csv"
OLLAMA_HOST=$(hostname)

# Check if prompt.txt exists
if [ ! -f "$PROMPT_FILE" ]; then
  echo "Error: prompt.txt not found in the current directory."
  exit 1
fi

# Function to unload all running models in ollama
unload_models() {
  echo "Checking for loaded models..."
  while true; do
    active_models=$(ollama ps | tail -n +2 | awk '{print $1}' | grep -v '^$')
    if [ -z "$active_models" ]; then
      echo "No models are currently loaded."
      break
    fi
    for active_model in $active_models; do
      echo "Stopping active model: $active_model"
      ollama stop "$active_model"
    done
    echo "Verifying unload..."
    sleep 1
  done
}

# Determine which models to run
if [ $# -gt 0 ]; then
  models="$*"
else
  models=$(ollama list | tail -n +2 | awk '{print $1}' | grep -v '^$')
fi

if [ -z "$models" ]; then
  echo "No local ollama models found. Please pull some models first."
  exit 1
fi

# Reset/initialize CSV file by deleting it first so the Python script can recreate it with a fresh header
rm -f "$CSV_FILE"

echo "Found the following models to benchmark:"
for model in $models; do
  echo "  - $model"
done
echo "----------------------------------------"

for model in $models; do
  echo "=== Benchmarking model: $model ==="
  
  # 1. Unload any currently running models
  unload_models
  
  # 2. Define safe file name for outputs (replacing slashes and colons with underscores)
  safe_model_name=$(echo "$model" | tr '/:' '_')
  output_file="${safe_model_name}_output.txt"
  temp_err_file="${safe_model_name}_stderr.tmp"
  
  # 3. Run prompt against the model with --verbose
  echo "Running model $model..."
  ollama run --verbose "$model" < "$PROMPT_FILE" > "$output_file" 2> "$temp_err_file"
  
  # Append stderr to the output file so it saves all output as requested
  cat "$temp_err_file" >> "$output_file"
  
  # 4. Parse statistics using Python
  python3 -c "
import sys, os, re, csv

def parse_duration(val_str, target_unit):
    match = re.match(r'([\d\.]+)\s*([a-zA-Zµμ]+)', val_str.strip())
    if not match:
        return 0.0
    val = float(match.group(1))
    unit = match.group(2).replace('μ', 'µ')
    if unit == 'ns':
        ns = val
    elif unit in ('µs', 'us'):
        ns = val * 1000.0
    elif unit == 'ms':
        ns = val * 1_000_000.0
    elif unit == 's':
        ns = val * 1_000_000_000.0
    elif unit == 'm':
        ns = val * 60_000_000_000.0
    else:
        ns = val
    if target_unit == 's':
        return ns / 1_000_000_000.0
    elif target_unit == 'ms':
        return ns / 1_000_000.0
    return ns

def parse_stats(stderr_path):
    stats = {
        'total duration': 0.0,
        'load duration': 0.0,
        'prompt eval count': 0.0,
        'prompt eval duration': 0.0,
        'prompt eval rate': 0.0,
        'eval count': 0.0,
        'eval duration': 0.0,
        'eval rate': 0.0
    }
    if not os.path.exists(stderr_path):
        return stats
    with open(stderr_path, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()
    
    def find_val(pattern, text):
        m = re.search(pattern, text)
        return m.group(1) if m else ''

    td_str = find_val(r'total duration:\s*([^\n\r]+)', content)
    ld_str = find_val(r'load duration:\s*([^\n\r]+)', content)
    pec_str = find_val(r'prompt eval count:\s*(\d+)', content)
    ped_str = find_val(r'prompt eval duration:\s*([^\n\r]+)', content)
    per_str = find_val(r'prompt eval rate:\s*([\d\.]+)', content)
    ec_str = find_val(r'(?<!prompt )eval count:\s*(\d+)', content)
    ed_str = find_val(r'(?<!prompt )eval duration:\s*([^\n\r]+)', content)
    er_str = find_val(r'(?<!prompt )eval rate:\s*([\d\.]+)', content)
    
    if td_str: stats['total duration'] = parse_duration(td_str, 's')
    if ld_str: stats['load duration'] = parse_duration(ld_str, 'ms')
    if pec_str: stats['prompt eval count'] = float(pec_str)
    if ped_str: stats['prompt eval duration'] = parse_duration(ped_str, 'ms')
    if per_str: stats['prompt eval rate'] = float(per_str)
    if ec_str: stats['eval count'] = float(ec_str)
    if ed_str: stats['eval duration'] = parse_duration(ed_str, 's')
    if er_str: stats['eval rate'] = float(er_str)
    return stats

model = sys.argv[1]
stderr_path = sys.argv[2]
csv_path = sys.argv[3]
host = sys.argv[4]
stats = parse_stats(stderr_path)
file_exists = os.path.exists(csv_path)
with open(csv_path, 'a', newline='', encoding='utf-8') as f:
    writer = csv.writer(f)
    if not file_exists:
        writer.writerow([
            'host',
            'model',
            'total duration (s)',
            'load duration (ms)',
            'prompt eval count (s)',
            'prompt eval duration (ms)',
            'prompt eval rate (tokens / s)',
            'eval count (tokens)',
            'eval duration (s)',
            'eval rate (tokens / s)'
        ])
    writer.writerow([
        host,
        model,
        f'{stats[\"total duration\"]:.6f}',
        f'{stats[\"load duration\"]:.6f}',
        int(stats[\"prompt eval count\"]),
        f'{stats[\"prompt eval duration\"]:.6f}',
        f'{stats[\"prompt eval rate\"]:.2f}',
        int(stats[\"eval count\"]),
        f'{stats[\"eval duration\"]:.6f}',
        f'{stats[\"eval rate\"]:.2f}'
    ])
" "$model" "$temp_err_file" "$CSV_FILE" "$OLLAMA_HOST"

  # Clean up temp file
  rm -f "$temp_err_file"
  echo "Done benchmarking $model."
  echo "----------------------------------------"
done

echo "Benchmarking complete. Results written to $CSV_FILE."
