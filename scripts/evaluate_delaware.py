"""Frozen random public-data diagnostic; no training or sealed-test access.

Run sample, author blind reference.jsonl, freeze-reference, then predict with each
model's existing isolated interpreter. Raw records and judgments stay in .local/.
"""
import argparse
import concurrent.futures
import hashlib
import json
import math
import os
from pathlib import Path
import random
import shutil
import time
import urllib.parse
import urllib.request

ROOT = Path('.local/real-eval/delaware-100-20261017-v1')
ENDPOINT = 'https://data.delaware.gov/resource/nurt-5rqw.json'
METADATA = 'https://data.delaware.gov/api/views/nurt-5rqw.json'
SEED = 20261017


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')


def rows(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line]


def request(url, params=None):
    if params:
        url += '?' + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={'User-Agent': 'GroundKeeper-public-data-diagnostic'})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def sample():
    if ROOT.exists():
        raise FileExistsError('Preserve the existing sample; do not resample after predictions')
    before = request(METADATA)
    count = int(request(ENDPOINT, {'$select': 'count(*) as n'})[0]['n'])
    ROOT.mkdir(parents=True)
    offsets = random.Random(SEED).sample(range(count), 100)
    write_json(ROOT / 'sampling_plan.json', {'seed': SEED, 'population_rows': count,
               'offsets_in_sample_order': offsets, 'rows_updated_at': before['rowsUpdatedAt']})
    start = time.monotonic()

    def fetch(item):
        index, offset = item
        if time.monotonic() - start > 480:
            raise TimeoutError('Sampling phase time bound')
        value = request(ENDPOINT, {'$select': ':id as source_row_id,merchant',
                        '$order': ':id', '$offset': offset, '$limit': 1})
        if len(value) != 1 or not value[0].get('merchant', '').strip():
            raise ValueError(f'Unexpected row at offset {offset}; no replacement sampling')
        return {'id': f'delaware-100-{index + 1:03d}', 'source_row_id': value[0]['source_row_id'],
                'source_offset': offset, 'input': {'description': value[0]['merchant'],
                                                  'direction': 'unknown', 'currency': None}}

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        selected = []
        for value in pool.map(fetch, enumerate(offsets)):
            selected.append(value)
            if len(selected) % 10 == 0:
                print(json.dumps({'phase': 'sample', 'done': len(selected), 'n': 100}), flush=True)
    after = request(METADATA)
    after_count = int(request(ENDPOINT, {'$select': 'count(*) as n'})[0]['n'])
    if before['rowsUpdatedAt'] != after['rowsUpdatedAt'] or count != after_count:
        raise ValueError('Source changed during sampling; preserve evidence and investigate')
    if len({r['source_row_id'] for r in selected}) != 100:
        raise ValueError('Stable row identifiers are not unique')
    target = ROOT / 'sample.jsonl'
    target.write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in selected))
    manifest = {'dataset': ENDPOINT, 'metadata': METADATA, 'seed': SEED, 'n': 100,
                'population_rows': count, 'rows_updated_at': before['rowsUpdatedAt'],
                'sampling': 'uniform transaction rows without replacement; stable :id order; full source history',
                'sample_sha256': digest(target), 'direction': 'unknown', 'currency': None,
                'input_scope': 'merchant text only; no amount, MCC, agency, date or source label supplied',
                'reference_status': 'pending_blind_ai_review', 'human_labels': 0,
                'training_allowed': False, 'existing_sealed_test_read': False,
                'unique_descriptions': len({r['input']['description'] for r in selected}),
                'elapsed_seconds': time.monotonic() - start}
    write_json(ROOT / 'manifest.json', manifest)
    for packet in range(4):
        blind = [{'id': r['id'], 'input': r['input']} for r in selected[packet * 25:(packet + 1) * 25]]
        write_json(ROOT / f'blind-packet-{packet + 1}.json', blind)
    print(json.dumps(manifest), flush=True)


def freeze_reference():
    from groundkeeper.policy import validate_answer
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    if manifest['reference_status'] != 'pending_blind_ai_review':
        raise ValueError('Reference already frozen')
    reference = rows(ROOT / 'reference.jsonl')
    sample_rows = rows(ROOT / 'sample.jsonl')
    if [r['id'] for r in reference] != [r['id'] for r in sample_rows]:
        raise ValueError('References must cover all 100 sampled rows in order')
    for r in reference:
        validate_answer(r['answer'])
        if not r.get('evidence') or r.get('reviewer') != 'Codex row-by-row AI review':
            raise ValueError('Evidence/reviewer missing')
    if list(ROOT.glob('*predictions.jsonl')):
        raise ValueError('Predictions already exist; cannot claim blind reference')
    manifest.update(reference_status='frozen_before_model_inference',
                    reference_sha256=digest(ROOT / 'reference.jsonl'),
                    reference_frozen_unix=time.time(),
                    policy_sha256=digest('experiments/finetune/LABELING_POLICY.md'),
                    policy_additions_sha256=digest('experiments/finetune/v2/POLICY_ADDITIONS.md'))
    write_json(ROOT / 'manifest.json', manifest)
    print('Frozen 100 blind AI-reviewed reference decisions; zero human confirmations.', flush=True)


def predict(name):
    os.environ.update(HF_HUB_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1', TOKENIZERS_PARALLELISM='false')
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    if manifest['reference_status'] != 'frozen_before_model_inference':
        raise ValueError('Freeze blind references before inference')
    for filename, key in [('sample.jsonl', 'sample_sha256'), ('reference.jsonl', 'reference_sha256')]:
        if digest(ROOT / filename) != manifest[key]:
            raise ValueError(f'Frozen {filename} changed')
    target = ROOT / f'{name}-predictions.jsonl'
    if target.exists():
        raise FileExistsError('Preserve existing predictions; do not rerun for a better score')
    data = rows(ROOT / 'sample.jsonl')
    info = {'model': name, 'n': len(data), 'started_unix': time.time(),
            'sample_sha256': manifest['sample_sha256'], 'reference_sha256': manifest['reference_sha256']}
    if name == 'qwen':
        import mlx.core as mx
        from mlx_lm import load
        from groundkeeper.constraints import DecisionGrammar
        from groundkeeper.runtime_v2 import generate_decision
        mx.set_memory_limit(14_000_000_000)
        mx.set_cache_limit(512_000_000)
        source = Path('.local/finetune/v2/training/candidate-0/adapters')
        adapter = ROOT / 'qwen-adapter'
        adapter.mkdir(exist_ok=False)
        shutil.copy2(source / 'adapter_config.json', adapter / 'adapter_config.json')
        checkpoint = source / '0002080_adapters.safetensors'
        shutil.copy2(checkpoint, adapter / 'adapters.safetensors')
        model_path = Path('.local/finetune/models/qwen35-text')
        info.update(checkpoint=str(checkpoint), checkpoint_sha256=digest(checkpoint),
                    base_path=str(model_path), base_weight_hashes={p.name: digest(p) for p in sorted(model_path.glob('*.safetensors'))},
                    prompt_version='v2', decoder='constrained', step=2080)
        model, tokenizer = load(str(model_path), adapter_path=str(adapter))
        grammar = DecisionGrammar(tokenizer)
        def infer(inputs):
            return generate_decision(model, tokenizer, inputs, grammar, mode='constrained')
    else:
        import torch
        from groundkeeper.laya_runtime import LocalLayaCategorizer
        package = Path('.local/laya/package')
        package_manifest = json.loads((package / 'manifest.json').read_text())
        compatibility_changes = []
        for rel, record in package_manifest['files'].items():
            actual_hash = digest(package / rel)
            if actual_hash == record['sha256']:
                continue
            # The existing packager hashes before runtime reload. Upstream Laya
            # rewrites this one config during that reload; verify the exact
            # documented transformation against the immutable selected checkpoint.
            if rel != 'tokenizer/tokenizer_config.json':
                raise ValueError(f'Packaged Laya artifact changed: {rel}')
            original = Path('.local/laya/training') / f"checkpoint-epoch-{package_manifest['selected_epoch']}" / rel
            if digest(original) != record['sha256']:
                raise ValueError('Original tokenizer config does not match packaged manifest')
            normalized = json.loads(original.read_text())
            if normalized.get('tokenizer_class') != 'TokenizersBackend':
                raise ValueError('Unexpected tokenizer compatibility input')
            normalized['tokenizer_class'] = 'PreTrainedTokenizerFast'
            normalized.pop('backend', None)
            normalized.pop('is_local', None)
            if json.loads((package / rel).read_text()) != normalized:
                raise ValueError('Tokenizer difference exceeds the upstream compatibility rewrite')
            compatibility_changes.append({'file': rel, 'original_sha256': record['sha256'],
                                          'runtime_sha256': actual_hash,
                                          'reason': 'verified upstream Laya tokenizer-class compatibility rewrite'})
        if digest('groundkeeper/laya_runtime.py') != package_manifest['files']['groundkeeper/laya_runtime.py']['sha256']:
            raise ValueError('Current Laya runtime differs from the tested package')
        model = LocalLayaCategorizer(package, device='mps')
        info.update(checkpoint=str(package), checkpoint_sha256=package_manifest['files']['model.safetensors']['sha256'],
                    epoch=package_manifest['selected_epoch'], decoder='existing_joint_constrained', device='mps',
                    verified_compatibility_changes=compatibility_changes)
        def infer(inputs):
            value = model.predict(inputs)
            torch.mps.synchronize()
            return value
    write_json(ROOT / f'{name}-run.json', info)
    start = time.monotonic()
    with target.open('x') as stream:
        for index, row in enumerate(data):
            if time.monotonic() - start > 1800:
                raise TimeoutError('Inference phase time bound')
            before = time.perf_counter()
            answer, detail = infer(row['input'])
            record = {'id': row['id'], 'prediction': answer, 'detail': detail,
                      'wall_seconds': time.perf_counter() - before}
            stream.write(json.dumps(record, ensure_ascii=False) + '\n')
            stream.flush()
            if (index + 1) % 10 == 0:
                print(json.dumps({'model': name, 'done': index + 1, 'n': len(data),
                                  'elapsed_seconds': time.monotonic() - start}), flush=True)
    info.update(completed=100, elapsed_seconds=time.monotonic() - start,
                predictions_sha256=digest(target), finished_unix=time.time())
    write_json(ROOT / f'{name}-run.json', info)
    print(json.dumps(info), flush=True)


def score():
    from groundkeeper.metrics import evaluate
    from groundkeeper.policy import validate_answer
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    sample_rows = rows(ROOT / 'sample.jsonl')
    references = rows(ROOT / 'reference.jsonl')
    if digest(ROOT / 'reference.jsonl') != manifest['reference_sha256']:
        raise ValueError('Reference changed after freeze')
    predictions = {name: rows(ROOT / f'{name}-predictions.jsonl') for name in ('qwen', 'laya')}
    expected_ids = [r['id'] for r in sample_rows]
    for values in [references, *predictions.values()]:
        if [r['id'] for r in values] != expected_ids or len(values) != 100:
            raise ValueError('Incomplete or misaligned predictions/references')
    gold = [r['answer'] for r in references]
    for value in gold + [r['prediction'] for records in predictions.values() for r in records]:
        validate_answer(value)

    def wilson(hits, n):
        z = 1.959963984540054
        p = hits / n
        denominator = 1 + z * z / n
        center = (p + z * z / (2 * n)) / denominator
        half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denominator
        return [center - half, center + half]

    report = {'n': 100, 'labels': 'one_Codex_blind_row_by_row_AI_reviewer_not_human_ground_truth',
              'reference_frozen_before_inference': True, 'manifest': manifest,
              'real_data': True, 'institutional_card_data': True,
              'input_scope': manifest['input_scope'], 'models': {}}
    for name, records in predictions.items():
        values = [r['prediction'] for r in records]
        result = evaluate(gold, values)
        result['category_accuracy_wilson95'] = wilson(sum(g['category'] == p['category'] for g, p in zip(gold, values)), 100)
        result['invalid_outputs'] = sum(not r['detail'].get('valid_schema', False) for r in records)
        result['mean_wall_seconds'] = sum(r['wall_seconds'] for r in records) / 100
        result['run'] = json.loads((ROOT / f'{name}-run.json').read_text())
        unique_indices = list({r['input']['description']: i for i, r in enumerate(sample_rows)}.values())
        result['unique_description_metrics'] = evaluate([gold[i] for i in unique_indices], [values[i] for i in unique_indices])
        clear_indices = [i for i, r in enumerate(references) if r['reference_certainty'] == 'high']
        result['high_certainty_reference_metrics'] = evaluate([gold[i] for i in clear_indices], [values[i] for i in clear_indices])
        report['models'][name] = result
    q = [p['prediction']['category'] == g['category'] for p, g in zip(predictions['qwen'], gold)]
    l = [p['prediction']['category'] == g['category'] for p, g in zip(predictions['laya'], gold)]
    report['paired_category_results'] = {'both_correct': sum(a and b for a, b in zip(q, l)),
                                        'qwen_only_correct': sum(a and not b for a, b in zip(q, l)),
                                        'laya_only_correct': sum(b and not a for a, b in zip(q, l)),
                                        'both_wrong': sum(not a and not b for a, b in zip(q, l))}
    write_json(ROOT / 'results.json', report)
    review = ['# Delaware 100-transaction diagnostic review', '',
              'Reference decisions were written before model inference by one Codex AI reviewer. '
              'They are not human-confirmed ground truth. Merchant text only; direction unknown; currency null.', '',
              '| Metric | Qwen v2 | Laya epoch 3 |', '| --- | --- | --- |',
              f"| Category correct | {sum(q)}/100 | {sum(l)}/100 |",
              f"| Complete decision correct | {round(report['models']['qwen']['joint_accuracy'] * 100)}/100 | {round(report['models']['laya']['joint_accuracy'] * 100)}/100 |", '',
              'Reference certainty was recorded before inference: ' + ', '.join(
                  f"{sum(r['reference_certainty'] == level for r in references)} {level}"
                  for level in ('high', 'moderate', 'low')) + '. '
              'The file contains the original frozen reference, not corrected labels derived from model outputs.', '',
              '| ID | Published merchant text | Reference certainty | Reference type / category / review | Qwen | Laya | Reference evidence |',
              '| --- | --- | --- | --- | --- | --- | --- |']
    def decision(a):
        return f"{a['type']} / {a['category']} / {str(a['review']).lower()}"
    for index, (record, reference) in enumerate(zip(sample_rows, references)):
        def cell(name):
            a = predictions[name][index]['prediction']
            category = 'category correct' if a['category'] == reference['answer']['category'] else 'CATEGORY ERROR'
            joint = 'exact match' if a == reference['answer'] else 'decision differs'
            return decision(a) + '; ' + category + '; ' + joint
        cells = [record['id'], record['input']['description'], reference['reference_certainty'], decision(reference['answer']),
                 cell('qwen'), cell('laya'), reference['evidence']]
        review.append('| ' + ' | '.join(str(c).replace('|', '\\|').replace('\n', ' ') for c in cells) + ' |')
    (ROOT / 'review.md').write_text('\n'.join(review) + '\n')
    print(json.dumps({'paired': report['paired_category_results'], 'models': {
        name: {k: value[k] for k in ['category_accuracy', 'type_accuracy', 'review_accuracy',
                                   'joint_accuracy', 'macro_f1_supported_categories',
                                   'invalid_outputs', 'mean_wall_seconds', 'category_accuracy_wilson95']}
        for name, value in report['models'].items()}}, indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['sample', 'freeze-reference', 'predict', 'score'])
    parser.add_argument('--model', choices=['qwen', 'laya'])
    args = parser.parse_args()
    if args.phase == 'sample':
        sample()
    elif args.phase == 'freeze-reference':
        freeze_reference()
    elif args.phase == 'score':
        score()
    elif args.model:
        predict(args.model)
    else:
        parser.error('predict requires --model')
