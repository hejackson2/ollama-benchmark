# Ollama benchmark
<br>
This repository provides shell scripts that were vibe coded using various coding harnesses or agents like antigravity, claude, opencode, etc.<br>

The scripts will discover the models already installed on a given ollama server and will run each model sequentially using the same prompt in ```prompt.txt``` and save the output from each run to a file unique to the model.  The perfomance data from the '--verbose' flag will be captured and saved to a common CSV file for use in comparing the models against each other.<br>
There is a sample output file "sample__model_comparison.csv" included in this repository.
