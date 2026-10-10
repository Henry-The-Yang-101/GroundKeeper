# Apple Shortcuts categorization benchmark

The existing Shortcut was edited with Computer Use as **GK Categorize Cloud**.
It accepts transaction JSON as Shortcut Input, appends it to `prompt.txt`, calls
Apple's **Cloud** model with **Broad World Knowledge on**, **Text** output and
**Follow Up off**, then uses **Stop and Output** with the model's Response.
Missing input uses **Stop and Respond** with
`{"type":"unknown","category":"uncategorized","review":true}`; the CLI reports
`Running was cancelled` for this branch, so callers must supply input.

The first two Cloud Pro smoke calls failed with `Too many incoming requests`.
After switching to Cloud, the synthetic Tim Hortons smoke call succeeded and
the Python adapter independently returned valid dining JSON in 1.265 seconds.
This observation does not establish different numerical limits for the models.

The frozen, Apple-signed export is `GK Categorize Cloud.shortcut`. Measured
results and limitations are in `RESULTS.md`; the saved responses, hashes and
machine-readable report are under `cloud-world-v1/`.

## Calling the Shortcut

```sh
/usr/bin/shortcuts run 'GK Categorize Cloud' \
  --input-path request.txt --output-path response.txt
```

Input has exactly `description`, `direction` (`debit`, `credit`, `unknown`), and
`currency` (three-letter uppercase code or null). Output has exactly `type`,
`category`, and a Boolean `review`, checked by `groundkeeper.policy.parse_answer`.
The Python application adapter is `AppleShortcutCategorizer.suggest(inputs)`.
It always requires review, matching the local model's application behavior.
Errors raise explicitly rather than accepting an invented prediction.

## Reproduce or resume validation

```sh
.venv/bin/python -m scripts.benchmark_apple_shortcuts \
  --output .local/apple-shortcuts/cloud-world-v1 \
  --limit 279 --timeout 60 --session-seconds 1800 --interval 1
```

Run the same command to resume. Inspect active processes before launching;
never run two copies against the same output directory. The script saves every
response and stops on a service failure or timeout. Resuming requires identical
configuration, prompt, validation data and saved Qwen predictions. Do not edit
the live Shortcut while running or resuming this measurement. OS/service model
versions cannot be pinned and manifest files cannot detect manual UI edits.

Only `.local/finetune/v2/prepared/valid_records.jsonl` is evaluated: 279 public
synthetic/authored examples. No training rows, private bank transactions, gold
labels, source metadata, or either final-test partition are sent to Apple.
Each request contains only the three input fields; the Shortcut has the fixed
policy. Qwen comparison uses saved v2 candidate-0 step-2080 predictions on the
same row IDs. Apple has additional format instructions and world knowledge,
so this measures provider pipelines under the same labeling rules, not identical
prompts. Semantic review values are scored before the application forces review.

`responses.jsonl`, `manifest.json`, and `report.json` are saved under the output
directory. Invalid returned JSON receives zero accuracy credit. Service failures
are separate from completed examples; partial accuracy is compared with Qwen
on precisely the same subset and is not presented as a full-set result.
The labels are synthetic weak labels, so agreement is not real-world accuracy.

## On-device comparison

The user switched the live Shortcut to **On-Device** while retaining its name
**GK Categorize Cloud**. Verify the actual model in the editor before each run;
the name is not a reliable model indicator. The on-device comparison preserves
the same prompt, including its world-knowledge sentence, but this model has no
Broad World Knowledge toggle. No prompt repair or output correction is applied.

```sh
.venv/bin/python -m scripts.benchmark_apple_shortcuts \
  --config experiments/apple-shortcuts/config-on-device.json \
  --output .local/apple-shortcuts/on-device-v1 \
  --limit 279 --timeout 60 --session-seconds 3600 --interval 1
```

This uses a separate manifest and response log. Invalid decision schemas receive
zero accuracy credit even when their raw text is syntactically valid JSON.
Before resuming the older Cloud benchmark, restore its original Cloud model and
Broad World Knowledge settings; do not mix provider settings in one measurement.

The Shortcut accepts input and returns output in a live CLI smoke test while
the Mac is unlocked. Locked-screen/launchd behavior remains untested.
