"""Prepare and validate an 80-worker public Delaware weak-labeling job.

Raw text, annotation files, inventories, and job state remain under .local/.
This script never opens old test records or starts model training.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import random
import re
import unicodedata

from groundkeeper.policy import validate_answer, validate_input
from scripts.prepare_training import ALIASES, key
from scripts.prepare_v2_training import normalized_group

ROOT = Path('.local/delaware-labeling-v1')
DIAGNOSTIC = Path('.local/real-eval/delaware-100-20261017-v1/sample.jsonl')
FIELDS = {'id', 'type', 'category', 'review', 'merchant_group', 'evidence', 'disposition'}
EXTRA = {
    'amzn': 'amazon', 'amazonmktpl': 'amazon', 'amazonmktplacepmts': 'amazon',
    'stapls': 'staples', 'staplesprofessional': 'staples',
    'vzwrlss': 'verizon', 'verizonwrlss': 'verizon',
    'doubletree': 'hilton', 'hamptoninn': 'hilton', 'homewoodsuites': 'hilton',
    'embassysuites': 'hilton', 'hiltongardeninn': 'hilton',
    'courtyard': 'marriott', 'fairfieldinn': 'marriott', 'residenceinn': 'marriott',
    'sheraton': 'marriott', 'westin': 'marriott', 'ritzcarlt': 'marriott',
    'holidayinn': 'ihg', 'crowneplaza': 'ihg', 'staybridge': 'ihg', 'candlewoodsuites': 'ihg',
    'walmar': 'walmart', 'walmart': 'walmart', 'samsclub': 'walmart',
    'lowes': 'lowes', 'homedepot': 'homedepot', 'thehomedepot': 'homedepot',
    'dojinternaltransaction': 'dojinternal', 'dltcrp': 'dltcrp',
    'suezdel': 'suez', 'suez': 'suez',
}


def read(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def write(path, values):
    Path(path).write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in values))


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def family_name(value):
    value = normalized_group(value)
    return EXTRA.get(value, value)


def family(description, known):
    text = unicodedata.normalize('NFKC', description).upper().strip()
    text = re.sub(r'^(?:(?:SQ|TST|CLV|PAYPAL|PP|PYPL|PAR|FSP|SP|GAN|SLICE)\s*\*\s*)+', '', text)
    text_key = key(text)
    aliases = {**ALIASES, **EXTRA}
    for alias in sorted(aliases, key=len, reverse=True):
        if len(alias) >= 5 and text_key.startswith(alias):
            return family_name(aliases[alias])
    for group in sorted(known, key=len, reverse=True):
        if not group.startswith('generic:') and len(group) >= 5 and text_key.startswith(group):
            return family_name(group)
    # Group repeated store/order suffixes without altering the model's raw input.
    stem = re.split(r'[*#]|\d', text, maxsplit=1)[0]
    stem = re.sub(r'\b(?:INCORPORATED|INC|LLC|LTD|CORP|CORPORATION)\b\.?', '', stem).strip()
    result = key(stem)
    return family_name(result or text_key)


def prepare():
    if (ROOT / 'manifest.json').exists():
        raise FileExistsError('Frozen labeling inputs already exist; preserve assignments')
    inventory_path = ROOT / 'merchant_inventory.json'
    inventory = json.loads(inventory_path.read_text())
    manifest_paths = [Path('experiments/finetune/split_manifest.jsonl'),
                      Path('experiments/finetune/v2/split_manifest.jsonl')]
    old = [r for path in manifest_paths for r in read(path)]
    known = {family_name(r['group']) for r in old}
    old_holdout = {family_name(r['group']) for r in old if r['split'] != 'train'}
    old_train = {family_name(r['group']) for r in old if r['split'] == 'train'}
    diagnostic = read(DIAGNOSTIC)
    diagnostic_text = {r['input']['description'] for r in diagnostic}
    diagnostic_families = {family(r['input']['description'], known) for r in diagnostic}
    blocked = old_holdout | diagnostic_families
    # Build once and hash by source text. No source categories or inferred targets.
    ordered = sorted(inventory, key=lambda r: hashlib.sha256(
        ('gk-delaware-labeling-v1:' + r.get('merchant', '')).encode()).hexdigest())
    candidates, excluded = [], Counter()
    counts, normalized_seen = Counter(), set()
    for r in ordered:
        description = r.get('merchant', '')
        if not description.strip() or len(description.strip()) < 3 or len(description) > 180 or any(ord(c) < 32 for c in description):
            excluded['mechanically_invalid'] += 1
            continue
        group = family(description, known)
        if description in diagnostic_text or group in blocked:
            excluded['diagnostic_or_old_holdout_family'] += 1
            continue
        normalized = re.sub(r'\d+', '#', re.sub(r'\s+', ' ', description.casefold()).strip())
        if normalized in normalized_seen:
            excluded['normalized_duplicate'] += 1
            continue
        if counts[group] >= 2:
            excluded['provisional_family_cap_2'] += 1
            continue
        normalized_seen.add(normalized)
        counts[group] += 1
        candidates.append({'input': {'description': description, 'direction': 'unknown', 'currency': None},
                           'provisional_family': group, 'source_occurrences': int(r['occurrences'])})
    edge = re.compile(r'\b(?:FEE|FEES|VETERINARY|VETERINARIAN|ATTORNEY|ATTORNEYS|LEGAL|INSURANCE|PRINCIPAL|LOAN|MORTGAGE|PHARMACY|MEMBERSHIP|SHIPPING|COURT|NOTARY)\b', re.I)
    edge_rows = [r for r in candidates if edge.search(r['input']['description'])][:75]
    if len(edge_rows) != 75:
        raise ValueError('Need 75 difficult-case pilot inputs')
    edge_keys = {r['input']['description'] for r in edge_rows}
    rest = [r for r in candidates if r['input']['description'] not in edge_keys]
    random.Random(20261017).shuffle(rest)
    if len(rest) < 7925:
        raise ValueError('Insufficient diverse, excluded-family-safe inventory')
    assigned = []
    cursor = 0
    for worker in range(1, 81):
        initial = edge_rows[(worker - 1) * 25:worker * 25] if worker <= 3 else []
        take = 100 - len(initial)
        items = initial + rest[cursor:cursor + take]
        cursor += take
        out = ROOT / 'workers' / f'{worker:03d}'
        out.mkdir(parents=True, exist_ok=False)
        records = []
        for item in items:
            ident = f'de-real-{len(assigned) + 1:06d}'
            row = {'id': ident, **item, 'worker': worker,
                   'source': 'Delaware official institutional card merchant text',
                   'source_record_kind': 'published_exact_merchant_string',
                   'origin': 'real_public_card_data', 'label_status': 'pending_ai_annotation'}
            records.append(row)
            assigned.append(row)
        for packet in range(1, 5):
            blind = [{'id': r['id'], 'input': r['input']} for r in records[(packet - 1) * 25:packet * 25]]
            write(out / f'inputs_{packet:02d}.jsonl', blind)
    assert len(assigned) == len({r['input']['description'] for r in assigned}) == 8000
    write(ROOT / 'candidates.jsonl', assigned)
    (ROOT / 'exclusion_metadata.json').write_text(json.dumps({
        'old_train_families': sorted(old_train), 'old_holdout_families': sorted(old_holdout),
        'diagnostic_families': sorted(diagnostic_families),
        'old_split_manifest_sha256': {str(p): sha(p) for p in manifest_paths}}, indent=2) + '\n')
    report = {'status': 'inputs_frozen_pilot_pending', 'n': 8000, 'workers_requested': 80,
              'model_requested': 'gpt-6-luna', 'reasoning_effort_requested': 'xhigh',
              'rows_per_worker': 100, 'packets_per_worker': 4, 'rows_per_packet': 25,
              'user_authorized_100_per_agent': True, 'maximum_concurrent_subagents': 3,
              'selection': 'merchant-diverse hash order, cap two provisional family variants; 75 targeted boundary pilot rows',
              'source_is_uniform_transaction_sample': False, 'source_categories_visible': False,
              'input_contract': 'merchant text; direction unknown; currency null',
              'provisional_family_count': len({r['provisional_family'] for r in assigned}),
              'maximum_provisional_family_variants': max(Counter(r['provisional_family'] for r in assigned).values()),
              'provisional_known_families_excluded_before_labeling': True,
              'initial_family_matching_is_exhaustive': False,
              'final_group_audit_required': True, 'splits_frozen': False,
              'intended_splits': 'approximately 80/10/10 by audited merchant family; old-training families may only enter training',
              'training_started': False, 'human_labels': 0,
              'candidates_sha256': sha(ROOT / 'candidates.jsonl'),
              'inventory_sha256': sha(inventory_path), 'excluded_counts': dict(excluded),
              'policy_sha256': sha('experiments/finetune/LABELING_POLICY.md'),
              'policy_additions_sha256': sha('experiments/finetune/v2/POLICY_ADDITIONS.md')}
    (ROOT / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


def validate(worker, packet=None):
    out = ROOT / 'workers' / f'{worker:03d}'
    selected = range(1, 5) if packet is None else [packet]
    completed = 0
    for number in selected:
        inputs = read(out / f'inputs_{number:02d}.jsonl')
        labels = read(out / f'labels_{number:02d}.jsonl')
        if len(labels) != 25 or [r['id'] for r in labels] != [r['id'] for r in inputs]:
            raise ValueError(f'Worker {worker}, packet {number}: missing/reordered IDs')
        for label, source in zip(labels, inputs):
            if set(label) != FIELDS or label['disposition'] not in ('keep', 'reject'):
                raise ValueError(f'Wrong annotation schema: {label.get("id")}')
            validate_input(source['input'])
            validate_answer({k: label[k] for k in ('type', 'category', 'review')})
            if not all(isinstance(label[k], str) and label[k].strip() for k in ('merchant_group', 'evidence')):
                raise ValueError(f'Missing evidence/group: {label["id"]}')
            if label['category'] == 'other' and len(label['evidence'].split()) < 4:
                raise ValueError(f'Other needs named outside purpose: {label["id"]}')
        completed += 25
    print(json.dumps({'worker': worker, 'validated_rows': completed, 'packets': list(selected)}))


def audit(worker, check=False):
    """Blind 25-row second review; oversample policy boundaries, then hash sample."""
    folder = ROOT / 'audits' / f'{worker:03d}'
    if check:
        inputs, labels = read(folder / 'inputs.jsonl'), read(folder / 'labels.jsonl')
        assert len(labels) == 25 and [r['id'] for r in inputs] == [r['id'] for r in labels]
        for label in labels:
            assert set(label) == FIELDS and label['disposition'] in ('keep', 'reject')
            validate_answer({k: label[k] for k in ('type', 'category', 'review')})
            assert all(isinstance(label[k], str) and label[k].strip() for k in ('merchant_group', 'evidence'))
        print(json.dumps({'audit_worker': worker, 'validated_rows': 25}))
        return
    target = worker - 3 if worker > 3 else worker + 77
    inputs = [r for packet in range(1, 5) for r in read(ROOT / 'workers' / f'{target:03d}' / f'inputs_{packet:02d}.jsonl')]
    labels = [r for packet in range(1, 5) for r in read(ROOT / 'workers' / f'{target:03d}' / f'labels_{packet:02d}.jsonl')]
    by_id = {r['id']: r for r in labels}
    priority = lambda r: (0 if by_id[r['id']]['category'] in {'other','insurance','financial'} or by_id[r['id']]['type'] not in {'expense','unknown'} else 1,
                          hashlib.sha256(('audit-v1:' + r['id']).encode()).hexdigest())
    chosen = sorted(inputs, key=priority)[:25]
    folder.mkdir(parents=True, exist_ok=True)
    if (folder / 'inputs.jsonl').exists():
        assert read(folder / 'inputs.jsonl') == chosen
    else:
        write(folder / 'inputs.jsonl', chosen)
    print(json.dumps({'audit_worker': worker, 'target_worker': target, 'inputs': str(folder / 'inputs.jsonl'), 'n': 25}))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('phase', choices=['prepare', 'validate', 'audit-prepare', 'audit-validate'])
    p.add_argument('--worker', type=int)
    p.add_argument('--packet', type=int, choices=range(1, 5))
    a = p.parse_args()
    if a.phase == 'prepare':
        prepare()
    elif a.worker is None or not 1 <= a.worker <= 80:
        p.error('validate requires --worker 1..80')
    elif a.phase.startswith('audit-'):
        audit(a.worker, check=a.phase == 'audit-validate')
    else:
        validate(a.worker, a.packet)
