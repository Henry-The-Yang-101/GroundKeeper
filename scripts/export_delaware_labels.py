"""Audit and export Delaware weak labels without training either model.

Original worker annotations are immutable. Corrections and family overrides live
in separate local JSON files. No existing sealed test examples are opened.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re

from groundkeeper.laya_runtime import training_row
from groundkeeper.policy_v2 import messages_v2
from scripts.prepare_delaware_labels import ROOT, EXTRA, audit, family_name, read, sha, validate, write
from scripts.prepare_training import ALIASES, key
from scripts.prepare_v2_training import BANK_ALIASES, EXTRA_ALIASES

PARENT_ALIASES = {
    **ALIASES, **BANK_ALIASES, **EXTRA_ALIASES, **EXTRA,
    'uspostalservice': 'usps', 'unitedstatespostalservice': 'usps',
    'uspscom': 'usps', 'postalservice': 'usps',
    'unitedparcelservice': 'ups', 'theupsstore': 'ups', 'upsstore': 'ups',
    'federalexpress': 'fedex', 'fedexoffice': 'fedex',
    'notaryhotel': 'marriott', 'autographcollection': 'marriott',
    'autographnotaryhtl': 'marriott', 'hertrich': 'hertrich',
}


def canonical(value):
    value = re.sub(r'^(?:unknown|generic):', '', value.lower())
    value = key(value)
    seen = set()
    while value not in seen:
        seen.add(value)
        target = key(PARENT_ALIASES.get(value, family_name(value)))
        if target == value:
            return value
        value = target
    # Cross-generation alias dictionaries may form a parent/child cycle.
    return min(seen)


def text_identity(text, known):
    text = re.sub(r'^(?:(?:SQ|TST|CLV|PAYPAL|PP|PYPL|PAR|FSP|SP|GAN|SLICE)\s*\*\s*)+', '', text.upper())
    flat = key(text)
    for alias in sorted(set(PARENT_ALIASES) | known, key=lambda x: (-len(x), x)):
        if not flat.startswith(alias):
            continue
        # Short acronyms need an actual visible boundary, not a word fragment.
        if len(alias) < 5:
            pattern = r'^' + r'[^A-Z0-9]*'.join(re.escape(c) for c in alias.upper()) + r'(?:[^A-Z]|$)'
            if not re.match(pattern, text):
                continue
        return canonical(alias)
    stem = re.split(r'[*#]|\d', text, maxsplit=1)[0]
    stem = re.sub(r'\b(?:INCORPORATED|INC|LLC|LTD|CORP|CORPORATION)\b\.?', '', stem)
    return canonical(stem or flat)


def status():
    result = {}
    for worker in range(1, 81):
        paths = sorted((ROOT / 'workers' / f'{worker:03d}').glob('labels_*.jsonl'))
        result[f'{worker:03d}'] = sum(len(read(p)) for p in paths)
    audits = {f'{w:03d}': len(read(ROOT / 'audits' / f'{w:03d}' / 'labels.jsonl'))
              for w in range(1, 81) if (ROOT / 'audits' / f'{w:03d}' / 'labels.jsonl').exists()}
    state = json.loads((ROOT / 'coordinator_state.json').read_text())
    for w, n in result.items():
        if n:
            state['workers'].setdefault(w, {'agent': '/root/delaware_' + w})
            state['workers'][w].update({'primary_rows': n, 'audit_rows': audits.get(w, 0)})
    (ROOT / 'coordinator_state.json').write_text(json.dumps(state, indent=2) + '\n')
    print(json.dumps({'annotated_rows': sum(result.values()), 'audit_rows': sum(audits.values()),
                      'complete_workers': sum(n == 100 for n in result.values()),
                      'workers': {k: v for k, v in result.items() if v}}, indent=2))


def freeze():
    out = ROOT / 'prepared'
    if out.exists():
        raise FileExistsError('Preserve the frozen export; use a new version for changes')
    candidates = read(ROOT / 'candidates.jsonl')
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    assert sha(ROOT / 'candidates.jsonl') == manifest['candidates_sha256']
    assert sha('experiments/finetune/LABELING_POLICY.md') == manifest['policy_sha256']
    assert sha('experiments/finetune/v2/POLICY_ADDITIONS.md') == manifest['policy_additions_sha256']
    labels = []
    for worker in range(1, 81):
        validate(worker)
        for packet in range(1, 5):
            for row in read(ROOT / 'workers' / f'{worker:03d}' / f'labels_{packet:02d}.jsonl'):
                labels.append({**row, 'worker': worker, 'packet': packet,
                               'reviewer_model': 'gpt-6-luna', 'reasoning_effort': 'xhigh'})
    assert len(labels) == len({r['id'] for r in labels}) == 8000
    review_labels = []
    for worker in range(1, 81):
        audit(worker, check=True)
        review_labels += [{**r, 'audit_worker': worker, 'reviewer_model': 'gpt-6-luna',
                           'reasoning_effort': 'xhigh'} for r in read(ROOT / 'audits' / f'{worker:03d}' / 'labels.jsonl')]
    assert len(review_labels) == len({r['id'] for r in review_labels}) == 2000
    reviews = {r['id']: r for r in review_labels}
    source = {r['id']: r for r in candidates}
    changes = json.loads((ROOT / 'pilot_adjudications.json').read_text())['overrides']
    audit_path = ROOT / 'audit_adjudications.json'
    if audit_path.exists():
        changes += json.loads(audit_path.read_text())['overrides']
    fixes = {r['id']: r for r in changes}
    meta = json.loads((ROOT / 'exclusion_metadata.json').read_text())
    assert all(sha(path) == digest for path, digest in meta['old_split_manifest_sha256'].items())
    old_holdout = {canonical(g) for g in meta['old_holdout_families']}
    old_train = {canonical(g) for g in meta['old_train_families']}
    known = old_holdout | old_train | {canonical(g) for g in meta['diagnostic_families']}
    diagnostic = read('.local/real-eval/delaware-100-20261017-v1/sample.jsonl')
    diagnostic_groups = {text_identity(r['input']['description'], known) for r in diagnostic}
    blocked = old_holdout | diagnostic_groups | {canonical(g) for g in meta['diagnostic_families']}
    # Union every group clue, conservatively withholding entire connected families
    # if any alias was already in the diagnostic or a historical holdout.
    parent = {}
    def find(x):
        parent.setdefault(x, x)
        if parent[x] != x:
            parent[x] = find(parent[x])
        return parent[x]
    def union(a, b):
        a, b = find(a), find(b)
        if a != b:
            parent[max(a, b)] = min(a, b)
    clues = {}
    for label in labels:
        row = source[label['id']]
        group = fixes.get(label['id'], {}).get('merchant_group', label['merchant_group'])
        groups = {canonical(row['provisional_family']), canonical(group),
                  text_identity(row['input']['description'], known)} - {''}
        if label['id'] in reviews:
            groups.add(canonical(reviews[label['id']]['merchant_group']))
            groups.discard('')
        if not groups:
            raise ValueError(f'No meaningful family {row["id"]}')
        for g in groups:
            union(min(groups), g)
        clues[row['id']] = groups
    blocked_components = {find(g) for g in blocked}
    train_components = {find(g) for g in old_train}
    accepted, quarantine, disagreements = [], [], []
    assignments = {}
    for label in labels:
        row = source[label['id']]
        fix = fixes.get(label['id'], {})
        answer = fix.get('answer', {k: label[k] for k in ('type', 'category', 'review')})
        family = find(min(clues[label['id']]))
        merged = {**row, 'answer': answer, 'merchant_family': family,
                  'annotation': label, 'evidence': fix.get('evidence', label['evidence']),
                  'adjudicated': bool(fix), 'label_status': 'ai_weak_label_not_human_confirmed',
                  'human_confirmed': False}
        review = reviews.get(label['id'])
        conflict = review is not None and (answer != {k: review[k] for k in ('type','category','review')}
                                           or label['disposition'] != review['disposition'])
        if conflict:
            disagreements.append({'id': label['id'], 'primary_effective': answer,
                                  'independent': {k: review[k] for k in ('type','category','review')},
                                  'resolved_by_coordinator': bool(fix)})
        merged['independent_audit'] = 'coordinator_adjudicated' if fix else 'disagreed' if conflict else 'agreed' if review else 'not_sampled'
        reason = None
        if family in blocked_components:
            reason = 'diagnostic_or_historical_holdout_family_overlap'
        elif label['disposition'] == 'reject':
            reason = 'worker_rejected'
        elif conflict and not fix:
            reason = 'independent_review_disagreement_pending_adjudication'
        if reason:
            quarantine.append({**merged, 'quarantine_reason': reason})
            continue
        if family not in assignments:
            bucket = int(hashlib.sha256(('gk-real-delaware-v1:' + family).encode()).hexdigest(), 16) % 100
            assignments[family] = 'train' if family in train_components or bucket < 80 else 'valid' if bucket < 90 else 'test'
        accepted.append({**merged, 'split': assignments[family]})
    splits = {s: [r for r in accepted if r['split'] == s] for s in ('train', 'valid', 'test')}
    family_sets = {s: {r['merchant_family'] for r in rows} for s, rows in splits.items()}
    assert not any(family_sets[a] & family_sets[b] for a, b in [('train','valid'), ('train','test'), ('valid','test')])
    assert not any(r['merchant_family'] in blocked_components for r in accepted)
    out.mkdir()
    write(out / 'all_annotations.jsonl', labels)
    write(out / 'independent_audit_annotations.jsonl', review_labels)
    write(out / 'audit_disagreements.jsonl', disagreements)
    write(out / 'quarantine.jsonl', quarantine)
    write(out / 'split_manifest.jsonl', [{k: r[k] for k in ('id','merchant_family','split','label_status')} for r in accepted])
    for s, rows in splits.items():
        write(out / f'{s}.canonical.jsonl', rows)
        # Seal new real test separately; no trainer-facing test export.
        if s != 'test':
            write(out / f'{s}.qwen.jsonl', [{'messages': messages_v2(r['input'], r['answer'])} for r in rows])
            write(out / f'{s}.laya.jsonl', [training_row(r) for r in rows])
    report = {
        'status': 'complete_weak_labels_human_review_pending', 'primary_annotations': len(labels),
        'actual_primary_workers': len({r['worker'] for r in labels}),
        'rows_per_worker': dict(sorted(Counter(str(r['worker']) for r in labels).items(), key=lambda x:int(x[0]))),
        'annotator_model': 'gpt-6-luna', 'reasoning_effort': 'xhigh',
        'human_confirmed_labels': 0, 'training_started': False,
        'accepted': len(accepted), 'quarantined': len(quarantine),
        'quarantine_reasons': dict(Counter(r['quarantine_reason'] for r in quarantine)),
        'split_counts': {s: len(rows) for s, rows in splits.items()},
        'merchant_family_counts': {s: len(g) for s, g in family_sets.items()},
        'category_counts': dict(Counter(r['answer']['category'] for r in accepted)),
        'type_counts': dict(Counter(r['answer']['type'] for r in accepted)),
        'review_counts': dict(Counter(str(r['answer']['review']) for r in accepted)),
        'adjudications': len(fixes), 'merchant_family_audit': 'deterministic aliases plus three group clues unioned; not exhaustive ownership verification',
        'independent_audit_rows': len(review_labels),
        'independent_audit_sampling': '25 per primary worker; Other/financial/insurance/nonexpense prioritized, remaining hash-selected',
        'audit_disagreements_after_coordinator_corrections': len(disagreements),
        'unresolved_audit_disagreements_in_exports': 0,
        'family_overlap_between_splits': 0, 'known_holdout_or_diagnostic_overlap_in_exports': 0,
        'source': json.loads((ROOT / 'inventory_manifest.json').read_text()),
        'sampling': manifest['selection'], 'representative_personal_banking_sample': False,
        'input_features': ['description', 'direction=unknown', 'currency=null'],
        'limitations': ['AI labels are weak supervision, not human gold.',
                       'Public institutional card merchant strings; not personal Canadian chequing narrations.',
                       'Merchant-diverse selection changes prevalence; scores are not population accuracy.',
                       'Merchant identity cannot establish hidden purchase purpose.',
                       'New test labels need independent human review before accuracy claims.',
                       'Family aliases may miss undocumented ownership relationships.'],
        'sha256': {p.name: sha(p) for p in sorted(out.glob('*.jsonl'))},
    }
    (out / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    (out / 'README.md').write_text(
        '# Delaware real merchant-text weak labels\n\n'
        f'8,000 primary annotations from 80 Luna 6 xhigh workers; 2,000 blind second reviews. '
        f'{len(accepted):,} retained; {len(quarantine):,} quarantined. Zero human-confirmed labels.\n\n'
        'No model has been trained on these files. This is a merchant-diverse sample '
        'of public Delaware government card data, not a representative consumer bank dataset. '
        'Hidden source categories, amounts, agencies and purchase details were not inference features.\n\n'
        '`train.qwen.jsonl` and `valid.qwen.jsonl` use the existing v2 chat prompt. '
        '`train.laya.jsonl` and `valid.laya.jsonl` use the existing three-head decision contract. '
        'Both exports contain exactly the same accepted transactions and targets. '
        'Never train on `test.canonical.jsonl`; independently human-review its weak labels before accuracy claims.\n\n'
        '`*.canonical.jsonl` preserve source, input, answer, evidence, original annotation, '
        'review status, family and split. `all_annotations.jsonl` includes all 8,000 primary '
        'annotations, including quarantined rows. `independent_audit_annotations.jsonl` '
        'and `audit_disagreements.jsonl` preserve the separate audit. '
        '`quarantine.jsonl` records excluded rows and reasons. '
        '`manifest.json` records counts, limitations, source URL and artifact hashes.\n\n'
        'Merchant-family grouping uses conservative alias unions. Known prior held-out '
        'and diagnostic families are excluded. Old training families can enter only train. '
        'Unknown ownership relationships may remain; this is not an exhaustive corporate ownership audit.\n'
    )
    print(json.dumps({k: report[k] for k in ('accepted','quarantined','split_counts','category_counts')}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['status','freeze'])
    args = parser.parse_args()
    status() if args.phase == 'status' else freeze()
