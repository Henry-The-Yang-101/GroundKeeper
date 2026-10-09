"""Compare constrained decoding on unchanged v1 validation; no final-test access."""
import json
import argparse
import os
import time
from pathlib import Path

os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
import mlx.core as mx
from mlx_lm import load
from groundkeeper.constraints import DecisionGrammar, generate_constrained
from groundkeeper.runtime_v2 import generate_decision
from groundkeeper.policy import messages
from groundkeeper.metrics import evaluate
from scripts.full_common import read_rows, write_json, sha256


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--order',choices=['type-first','trained-order'],default='type-first')
    parser.add_argument('--mode',choices=['constrained','validated_retry'],default='constrained')
    args = parser.parse_args()
    order = ('type','category','review') if args.order=='type-first' else ('category','review','type')
    suffix = ('constrained-v1' if args.order=='type-first' else 'constrained-v1-trained-order')
    if args.mode == 'validated_retry':
        suffix += '-validated-retry'
    out = Path('.local/finetune/v2') / suffix
    if out.exists():
        raise FileExistsError('Refusing to overwrite measured decoding experiment')
    out.mkdir(parents=True)
    model_path = Path('.local/finetune/package-full-v1')
    model, tokenizer = load(str(model_path / 'model'), adapter_path=str(model_path / 'adapters'))
    mx.set_memory_limit(14_000_000_000)
    mx.set_cache_limit(512_000_000)
    grammar = DecisionGrammar(tokenizer,order)
    rows = read_rows('.local/finetune/prepared/valid_records.jsonl')
    predictions = []
    start = time.monotonic()
    for index, row in enumerate(rows):
        prediction, detail = generate_decision(model, tokenizer, row['input'], grammar,
                                               args.mode, messages)
        predictions.append({'id': row['id'], 'prediction': prediction, **detail})
        if (index + 1) % 20 == 0:
            print(json.dumps({'evaluated': index + 1, 'total': len(rows)}), flush=True)
    metrics = evaluate([r['answer'] for r in rows], [r['prediction'] for r in predictions])
    baseline = json.loads(Path('experiments/finetune/full-results/validation-0000512.json').read_text())
    for source in sorted({row['source'] for row in rows}):
        indices = [i for i, row in enumerate(rows) if row['source'] == source]
        metrics.setdefault('by_source', {})[source] = evaluate(
            [rows[i]['answer'] for i in indices], [predictions[i]['prediction'] for i in indices])
    report = {'metrics': metrics, 'invalid_outputs': 0, 'failures': 0,
              'allowed_canonical_answers': len(grammar.answers),
              'max_answer_tokens': grammar.max_answer_tokens,
              'elapsed_seconds': time.monotonic() - start,
              'mlx_peak_bytes': mx.get_peak_memory(),
              'same_model_same_prompt': True, 'changed': 'finite JSON decoding', 'key_order':order,
              'mode':args.mode,'constrained_retries':sum(r['constrained_retry'] for r in predictions),
              'unconstrained_category_accuracy': baseline['metrics']['category_accuracy'],
              'unconstrained_macro_f1': baseline['metrics']['macro_f1_supported_categories'],
              'validation_sha256': sha256('.local/finetune/prepared/valid_records.jsonl'),
              'adapter_sha256': sha256(model_path / 'adapters/adapters.safetensors'),
              'constraint_code_sha256': sha256('groundkeeper/constraints.py'),
              'real_validation': False, 'final_test_accessed': False}
    (out / 'predictions.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in predictions))
    write_json(out / 'report.json', report)
    print(json.dumps({k:v for k,v in report.items() if k != 'metrics'}), flush=True)
    print(json.dumps({k:v for k,v in metrics.items() if k not in ['per_category','by_source']}), flush=True)


if __name__ == '__main__':
    main()
