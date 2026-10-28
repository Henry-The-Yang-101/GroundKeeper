# Qwen evidence-v3

Active user-requested project: repair exactly 5,000 Delaware descriptions with
GPT-6.1 Sol high reviewers using internet research, copy and independently relabel
the user's approximately 1,200 private transactions, collect actual production
DuckDuckGo evidence, train a new adapter from the original Qwen3.5-4B text-only
4-bit base, review predictions individually, and use justified training errors
for supervised correction. Existing models and the live vault remain preserved.

This document is a plan and operating record, not evidence of completed training
or improved accuracy. Do not claim a new model until package and held-out results
exist. AI-researched reference agreement is not human-gold purchased-item truth.

## Frozen source and separation

`python -m scripts.prepare_evidence_v3 freeze-public` freezes 4,000 historical
training, 500 validation and 500 test rows. The seed is fixed before any scoring.
Historical cross-split family conflicts are excluded; audit-exposed test families
are excluded. Old labels do not enter review packets. Existing source artifacts
are hashed and unchanged. Reference repair of test rows is independent of model
predictions. The final test remains unavailable to training/model selection.

Sources and public review packets: `.local/finetune/evidence-v3/`.
Private snapshot, inputs, labels, combined training data: `.private/qwen-evidence-v3/`.
The snapshot uses read-only SQLite online backup. Access/encryption failures must
be resolved through supported user access, never by dumping secrets.

The actual snapshot contains **1,205 active transactions**. Training uses the
separate `snapshot/classifier_inputs.exact.jsonl` export and
`source-exact/personal.jsonl`: descriptions and supplied evidence match app
inputs. The earlier minimized export is preserved but is not the training source.
Private query projection uses stored merchant names and configured locality via
`MerchantTrainingQueryPilot`; public descriptions use the original fallback pilot.

Reviewers follow [EVIDENCE_V3_REVIEWER_GUIDE.md](EVIDENCE_V3_REVIEWER_GUIDE.md).
Resolved merchant identities must be audited across both sources before the
final split freeze. Keep related merchant variants/identical evidence within one
split. Historical train/validation/test ownership cannot silently migrate.

## Actual context collection

Use `scripts/collect_training_context.py` and the pinned DDGS environment:

```sh
PYTHONPATH=. .local/merchant-search-ddgs/venv/bin/python scripts/collect_training_context.py prepare --input .local/finetune/evidence-v3/source/delaware.jsonl --output-dir .local/finetune/evidence-v3/context/public
PYTHONPATH=. .local/merchant-search-ddgs/venv/bin/python scripts/collect_training_context.py collect --output-dir .local/finetune/evidence-v3/context/public --max-lookups 100 --max-seconds 1800
.venv/bin/python -m scripts.prepare_evidence_v3 packets
```

The collector uses the real Swift merchant-query sanitizer and Python production
MerchantSearch. Only sanitized merchant/locality are queried. Use separate
private output directories, but serialize public/private collection so pacing
is respected globally. Stop on provider blocks/unavailability and retain pending
rows; resume only after the persisted production backoff. Never use alternate
engines or fabricated context to fill failures. Context versions and hashes are
immutable. Manual labeler research is independent from model input context.

Private collection additionally rejects residual reference-like tokens before
cache or network access. This is a documented training privacy guard above the
production sanitizer, not a different search provider or fabricated context.
Its version, source hash and effective query candidates are frozen alongside
the private collection. Version 2 also rejects the all-letter references used
by two mobile-transit descriptor forms. Version 3 additionally withholds private
PAYPAL descriptors and DR/DR./DOCTOR prefixes. A local inspection of all 470
distinct nonempty frozen queries confirmed that these rules cover 105 rows to
withhold, including two possible personal-name queries. Twelve historical network
attempts now fall under rejection; those records remain unchanged. The additional
uncollected all-letter reference is blocked before dispatch. New packets hide
these unsafe queries from labelers; immutable
older packets retain truthful provenance and reviewers withhold unsafe queries.
Privacy-blocked research is recorded as attempted=false rather than pretending
that an internet lookup occurred.

The explicit `migrate-private-guard --output-dir PRIVATE_CONTEXT_DIRECTORY`
command archives each predecessor guard, effective candidates and record byte
hashes before activating the next version. Separate immutable journals retain
the version-1 to version-2 to version-3 chain and permit interrupted-migration
recovery. Run it while private collection is stopped, using the collector's
exclusive lock; never rewrite historical records or bypass a source-hash failure.

Operational progress lives in `.local/finetune/evidence-v3/RUN_STATE.json` and
`.venv/bin/python -m scripts.prepare_evidence_v3 status`. Revalidate process and
agent handles; saved state alone does not prove that a job is still running.
Packet generation is resumable and only creates inputs for collected records.

The training driver is documented in
[`scripts/evidence_training/README.md`](../../scripts/evidence_training/README.md).
A real GPU smoke run validated fitting, checkpoint inference, packaging and
final scoring on three fictional rows. It is not the requested new model.
The separate 40-row current-Delaware diagnostic uses TRAIN records only. Its
independent prediction checks and reference adjudications are retained privately;
one reference was revised. The four-row adjudication encountered prediction
references embedded in prior verdict rationales and is explicitly not blind.
No final-test predictions were used in that diagnostic.

## Reference acceptance

`python -m scripts.assemble_evidence_v3 triage --destination PRIVATE_AUDIT_PATH`
checks immutable source, context, packet and label bindings and produces a
merchant-family plan. Partial triage is useful during collection, but it does
not accept data. Final assembly requires all 6,205 individually reviewed source
IDs, plus separate evidence-bound adjudications for risky family merges. A
cross-split family cannot be accepted into training: correct an erroneous alias
with evidence or explicitly quarantine the component. Preserve all reviewed rows
in the audit, including quarantined rows, and protect excluded aliases in the
complete historical registry.

Audit identical visible inputs for conflicting type/category targets before
acceptance. Corrections require research adjudication and preserved prior labels;
do not enforce agreement by majority vote. Later completed labels can introduce
new conflicts, so repeat this check over the full cohort. Detailed review
disclosures must distinguish model-prediction exposure from prior-reference
exposure; a separate reviewer is not automatically a blinded reviewer.

## Training and assessment

Freeze current prompt/schema/tokenizer/decoder and use independent context and
no-context labels. Source base hash is expected to be
`d58b87def677c7b3235e21cdca85289a162a5ba8949687b9573592e3c74cd477`;
verify actual files before training. Start fresh LoRA rank8/last4 layers, with
assistant-only loss, small learning rate and complete evidence/answer tokens.
Do not inherit the old adapter, truncate decisive evidence, or replace packages.

Evaluate current preserved packages under the same current runtime policy and
frozen evidence. Report type/category agreement, per-category support and F1,
specific-suggestion coverage/errors, Other subtype, context gains/regressions,
source slices, latency and memory. New weights must show a substantial measured
improvement on held-out real inputs, not merely lower training loss. An initial
ambition is 10 percentage points in joint type/category agreement with improved
macro-F1 and no material private-source regression; this is not a promised result.

After initial training, GPT-6.1 Sol high reviewers inspect predictions one by one
with researched evidence. Corrected TRAIN examples feed supervised learning via
backpropagation, mixed with retained correct/rare examples. Do not train on
held-out corrections. Keep indeterminate cases distinct. Select on validation,
freeze, then perform a single final test comparison and preserve all results.
