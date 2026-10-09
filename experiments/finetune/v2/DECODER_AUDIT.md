# Constrained JSON audit

The contract has 92 schema-valid canonical JSON decisions. The local decoder
builds a token trie for those complete decisions, masks other tokens during
generation, requires a legal stop and validates the completed JSON. It covers
all three fields and the conditional null/Uncategorized/review rules. A valid
structure does not establish correct merchant interpretation.

Unit tests walk every grammar path, verify invalid prefixes and premature stops
fail closed, and check MLX logit masking. The MLX generator evaluates one token
ahead at EOS; an initial compatibility test found this and the decoder now
handles that internal step without allowing user-visible text after the object.
The failed run is preserved locally; it produced no completed evaluation report.

Three decoder configurations were evaluated using identical v1 checkpoint 512
weights, the unchanged v1 prompt and the same 116-row validation set. No final
test was accessed. The v1 target order was category/review/type, although JSON
objects semantically have no required key order.

| Decoder | Category accuracy | Supported-label macro-F1 | Exact three-field accuracy | Invalid returned decisions |
|---|---:|---:|---:|---:|
| Original generation + invalid-to-unknown fallback | 69.0% | 0.661 | 62.9% | 10 raw invalid outputs, normalized by fallback |
| Always constrained, type/category/review | 58.6% | 0.591 | 48.3% | 0/116 |
| Always constrained, trained category/review/type order | 67.2% | 0.655 | 61.2% | 0/116 |
| Validate first draft, type-first constrained retry on invalid draft | 69.0% | 0.690 | 62.9% | 0/116 |

The retry strategy keeps every schema-valid first draft and regenerates only the
10 schema-invalid ones under the finite grammar. It preserves overall category
accuracy while changing which categories are correct, improving macro-F1 on this
validation set. It is a measured decoder improvement, not a trained-model gain
or real-world accuracy result. Record first-pass failures and final returned
validity separately; do not hide the ten invalid drafts.

V2 will train canonical type-first outputs with the audited prompt, so its
always-constrained path matches its training targets. Compare it with the
validated-retry strategy on frozen validation before choosing the final runtime.
V1 production/rollback artifacts and labels remain untouched. Both paths retain
application review until real held-out calibration exists. Runtime exceptions
must be surfaced/handled explicitly; do not claim all failures were predictions.
