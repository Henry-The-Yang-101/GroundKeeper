# Apple Cloud on Delaware validation: partial result

**75.0% category agreement and 45.0% exact three-field agreement on 140 rows.**
Apple's usage limit stopped the run before the remaining 532 validation rows.
These are agreement scores against **AI weak labels**, not independently verified
accuracy against human gold labels.

## Configuration and scope

The live **GK Categorize Cloud** Shortcut was inspected in Shortcuts and verified
as **Cloud**, **Broad World Knowledge on**, **Text** output, **Follow Up off**.
The existing prompt and input/output contract were preserved. No setting or
label was adjusted using the measured answers. Apple's serving-model version
is not exposed or pinned by this interface.

The new Delaware dataset has 672 retained validation rows from real public
institutional card merchant descriptions. They were ordered by SHA-256 of
`20261017:<row_id>` before inference, independently of reference labels. This
reduces file-order bias in the quota-limited subset; it does not make the source
dataset representative of Canadian personal banking or all Delaware spending.

Only `description`, `direction` and `currency` were passed to Apple. Direction
is unknown and currency null in these records. Reference answers, evidence,
source categories, agencies and amounts were not inference features. Training,
quarantine and sealed-test partitions were not evaluated.

## Results on completed rows

| Metric | Result |
| --- | ---: |
| Completed / planned | 140 / 672 |
| Category agreement | 105/140 (75.0%) |
| Transaction type agreement | 94/140 (67.1%) |
| Review flag agreement | 100/140 (71.4%) |
| Exact type + category + review agreement | 63/140 (45.0%) |
| Supported-category macro-F1 | 0.581 |
| Valid decision schemas | 139/140 (99.3%) |
| Parseable JSON objects | 140/140 (100%) |
| Service failures | 1, after the 140 completed responses |
| Mean / median request latency | 1.313 / 1.297 seconds |

An invalid decision receives zero credit on every accuracy field. The single
invalid decision was valid JSON but combined `type: unknown` with
`category: medical`, which violates the existing rule that unknown type must
use the abstention category. It was not silently corrected or retried.

Forty-two valid responses chose `unknown` where the reference type was `expense`;
three chose `expense` where the reference was `unknown`. These disagreements
account for most of the gap between category and complete-decision agreement.
They identify cases for human policy review, not proven model errors against
ground truth.

The completed subset contains 56 `uncategorized` references and 39 `dining`
references; 16 reference categories are represented. Many category supports are
one or two rows, so per-category ranking is unreliable. Full category counts
and metrics are in the machine-readable report. The full validation set contains
17 categories and only `expense`/`unknown` types; other transaction types are
outside this dataset's measured coverage.

## Quota stop and resume

The next request failed with:

> Error: You have reached the usage limit for this model. Please try again later.

No further requests or automatic retries were made. This is an observed stop
after 140 completed calls, not evidence of a universal numerical daily quota or
known reset time. Full-set Apple accuracy remains unknown.

The command in [DELAWARE_RUNBOOK.md](DELAWARE_RUNBOOK.md) resumes the remaining
532 rows after quota is available. All completed rows are skipped. Keep the
Shortcut model, world-knowledge setting and prompt unchanged when resuming;
hash checks protect the local dataset, prompt and configuration files.

## Evidence and checks

- [Frozen manifest](delaware-cloud-world-20261017-v1/manifest.json)
- [All raw responses and quota error](delaware-cloud-world-20261017-v1/responses.jsonl)
- [Metrics, disagreements and verification](delaware-cloud-world-20261017-v1/report.json)
- [Dataset provenance and label limitations](../../research/DELAWARE_LABELED_DATASET_2026-10-17.md)

Four adapter/scorer tests passed. The final accuracy counts were independently
recomputed from saved predictions, every valid raw response was reparsed, and
the input-data/configuration/prompt hashes were rechecked. Ten initial responses
were preserved through a scorer-test repair and reused without changing the
inference or repeating requests. No Qwen inference or comparison was performed
on this new validation set, and scores from different datasets are not used as
same-set baselines.
