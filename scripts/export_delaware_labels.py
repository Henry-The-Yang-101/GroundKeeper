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
from groundkeeper.policy import CATEGORIES, TYPES
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


def status(spawned=None):
    result = {}
    for worker in range(1, 81):
        paths = sorted((ROOT / 'workers' / f'{worker:03d}').glob('labels_*.jsonl'))
        result[f'{worker:03d}'] = sum(len(read(p)) for p in paths)
    audits = {f'{w:03d}': len(read(ROOT / 'audits' / f'{w:03d}' / 'labels.jsonl'))
              for w in range(1, 81) if (ROOT / 'audits' / f'{w:03d}' / 'labels.jsonl').exists()}
    state = json.loads((ROOT / 'coordinator_state.json').read_text())
    if spawned is not None:
        if not 1 <= spawned <= 80:
            raise ValueError('spawned must be in 1..80')
        for w in range(1, spawned + 1):
            state['workers'].setdefault(f'{w:03d}', {}).update({
                'agent': f'/root/delaware_{w:03d}', 'model': 'gpt-6-luna',
                'reasoning_effort': 'xhigh', 'spawn_confirmed': True})
    for w, n in result.items():
        if n:
            state['workers'].setdefault(w, {'agent': '/root/delaware_' + w})
            state['workers'][w].update({'primary_rows': n, 'audit_rows': audits.get(w, 0)})
    (ROOT / 'coordinator_state.json').write_text(json.dumps(state, indent=2) + '\n')
    print(json.dumps({'annotated_rows': sum(result.values()), 'audit_rows': sum(audits.values()),
                      'confirmed_worker_spawns': sum(bool(r.get('spawn_confirmed')) for r in state['workers'].values()),
                      'complete_workers': sum(n == 100 for n in result.values()),
                      'workers_in_progress': {k: v for k, v in result.items() if 0 < v < 100}}, indent=2))


def freeze():
    target = ROOT / 'prepared'
    out = ROOT / '.prepared-staging'
    if target.exists() or out.exists():
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
    original = {r['id']: r for r in labels}
    initial_agreements = sum(all(r[k] == original[r['id']][k] for k in ('type','category','review','disposition')) for r in review_labels)
    field_agreement = {k: sum(r[k] == original[r['id']][k] for r in review_labels) / len(review_labels)
                       for k in ('type','category','review')}
    source = {r['id']: r for r in candidates}
    old_train_path = Path('.local/finetune/v2/prepared/train_records.jsonl')
    old_config = json.loads(Path('experiments/finetune/v2/training_config.json').read_text())
    assert sha(old_train_path) == old_config['data_hashes']['train_records.jsonl']
    old_train_descriptions = {key(r['input']['description']) for r in read(old_train_path)}
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
        elif key(row['input']['description']) in old_train_descriptions:
            reason = 'normalized_description_already_in_old_training'
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
        'categories_without_examples': sorted(set(CATEGORIES) - {r['answer']['category'] for r in accepted}),
        'types_without_examples': sorted(set(TYPES) - {r['answer']['type'] for r in accepted}),
        'review_counts': dict(Counter(str(r['answer']['review']) for r in accepted)),
        'adjudications': len(fixes), 'merchant_family_audit': 'deterministic aliases plus three group clues unioned; not exhaustive ownership verification',
        'independent_audit_rows': len(review_labels),
        'independent_audit_initial_exact_agreements': initial_agreements,
        'independent_audit_initial_exact_agreement_rate': initial_agreements / len(review_labels),
        'independent_audit_initial_field_agreement': field_agreement,
        'independent_audit_sampling': '25 per primary worker; Other/financial/insurance/nonexpense prioritized, remaining hash-selected',
        'audit_disagreements_after_coordinator_corrections': len(disagreements),
        'unresolved_audit_disagreements_in_exports': 0,
        'family_overlap_between_splits': 0, 'known_holdout_or_diagnostic_overlap_in_exports': 0,
        'source': json.loads((ROOT / 'inventory_manifest.json').read_text()),
        'policy_sha256': manifest['policy_sha256'],
        'policy_additions_sha256': manifest['policy_additions_sha256'],
        'old_training_records_sha256': sha(old_train_path),
        'old_training_transactions': len(read(old_train_path)),
        'worker_guide_sha256': sha('research/DELAWARE_LABELING_WORKER_GUIDE.md'),
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
    (out / 'test.canonical.jsonl').chmod(0o400)
    out.rename(target)
    manifest.update({'status': report['status'], 'splits_frozen': True,
                     'prepared_manifest_sha256': sha(target / 'manifest.json'),
                     'final_group_audit_completed': 'conservative deterministic alias/identity union',
                     'accepted': len(accepted), 'quarantined': len(quarantine)})
    (ROOT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({k: report[k] for k in ('accepted','quarantined','split_counts','category_counts')}, indent=2))


def report():
    prepared = ROOT / 'prepared'
    data = json.loads((prepared / 'manifest.json').read_text())
    base = str(prepared.resolve())
    text = '# Delaware 8,000-description weak-label dataset\n\n'
    text += (f"Completed **{data['primary_annotations']:,} primary annotations** with "
             f"**{data['actual_primary_workers']} Luna 6 (`gpt-6-luna`) xhigh workers**, "
             '100 distinct descriptions each in four packets of 25. '
             f"There are **{data['independent_audit_rows']:,} additional blind second reviews**. "
             '**Zero labels are human-confirmed. No training was started.**\n\n')
    text += ('Both existing models were trained on the **same 2,077 unique synthetic, AI-reviewed transactions**. '
             'Laya expands each transaction into three decision items (6,231 per epoch); '
             'this does not mean 6,231 unique transactions. Its selected checkpoint is epoch 3. '
             'Qwen v2 configuration also records 2,077 training rows. '
             'See `experiments/laya/training_report.json` and `experiments/finetune/v2/training_config.json`.\n\n')
    text += (f"Retained **{data['accepted']:,}** descriptions; quarantined **{data['quarantined']:,}**.\n\n"
             '| Split | Transactions | Merchant families |\n|---|---:|---:|\n')
    for split, n in data['split_counts'].items():
        text += f"| {split} | {n:,} | {data['merchant_family_counts'][split]:,} |\n"
    text += '\nQuarantine reasons:\n\n'
    for reason, count in data['quarantine_reasons'].items():
        text += f'- {reason}: {count:,}\n'
    text += (f"\nBlind reviewers initially agreed on the complete decision and disposition for "
             f"{data['independent_audit_initial_exact_agreements']:,}/{data['independent_audit_rows']:,} "
             f"({data['independent_audit_initial_exact_agreement_rate']:.1%}). "
             'This is AI agreement on an intentionally boundary-heavy sample, not accuracy. '
             'Unresolved reviewed disagreements are excluded. Unreviewed rows remain weak labels.\n\n')
    text += ('Family unions join provisional selection groups, annotator groups, recognized raw-text aliases '
             'and independent reviewer groups. Known historical holdout and earlier 100-row diagnostic families '
             'are quarantined; old training families can enter only training. '
             'No recognized family crosses the new splits. Ownership aliases are not exhaustive.\n\n')
    text += '## Files\n\n'
    for filename, purpose in [('README.md','Export guide'),('manifest.json','Counts, provenance, limitations and hashes'),
                              ('train.canonical.jsonl','Training records with evidence'),('valid.canonical.jsonl','Validation records with evidence'),
                              ('train.qwen.jsonl','Qwen v2 training format'),('valid.qwen.jsonl','Qwen v2 validation format'),
                              ('train.laya.jsonl','Laya training format'),('valid.laya.jsonl','Laya validation format'),
                              ('all_annotations.jsonl','All 8,000 original primary annotations'),
                              ('quarantine.jsonl','Rows excluded pending review or because of family overlap'),
                              ('audit_disagreements.jsonl','Independent review disagreements')]:
        text += f'- [{purpose}]({base}/{filename})\n'
    text += ('\nThe new real test is `test.canonical.jsonl`, read-only and absent from trainer-facing exports. '
             'Keep it outside training; obtain independent human review before using it as a gold accuracy benchmark.\n\n')
    text += '## Verification\n\n'
    for provider in ('qwen','laya'):
        check_path = ROOT / 'verification' / f'{provider}.json'
        if check_path.exists():
            check = json.loads(check_path.read_text())
            assert check['manifest_sha256'] == sha(prepared / 'manifest.json') and check['passed']
            text += (f"- {provider}: export targets match canonical records; maximum sequence "
                     f"{check['maximum_sequence_tokens']}/512 tokens, no truncation. "
                     f"[Check result]({check_path.resolve()}).\n")
        else:
            text += f'- {provider}: tokenizer verification pending.\n'
    text += '\nNo inference or training was used in these checks; the new sealed test was not parsed.\n\n'
    text += '## Coverage\n\n| Category | Retained rows |\n|---|---:|\n'
    for category, n in sorted(data['category_counts'].items(), key=lambda x: str(x[0])):
        text += f'| {category} | {n:,} |\n'
    text += (f"\nCategories absent: {', '.join(data['categories_without_examples']) or 'none'}. "
             f"Types absent: {', '.join(data['types_without_examples']) or 'none'}.\n\n")
    text += ('## Provenance and limits\n\n'
             'Exact published merchant strings from [Delaware official card expenditure data]'
             '(https://data.delaware.gov/resource/nurt-5rqw.json), '
             '[metadata](https://data.delaware.gov/api/views/nurt-5rqw.json). '
             'The frozen inventory contains 436,557 distinct strings. Source categories, agencies, amounts, '
             'and dates were not labeling features; input is description, unknown direction, and null currency. '
             'Selection prioritizes merchant diversity and includes 75 targeted pilot rows; '
             'it is not a uniform transaction sample. These are real institutional US card merchant descriptions, '
             'not representative Canadian personal banking narrations.\n\n'
             'The pilot caught ambiguous merchant titles. Public merchant-identity references included '
             '[Business Insurance publication](https://www.businessinsurance.com/about/), '
             '[The Notary Hotel](https://www.marriott.com/hotels/travel/phlak-the-notary-hotel-philadelphia-autograph-collection/), '
             'and [Plumb’s reference software](https://plumbs.com/pricing/). '
             'These establish merchant identity, not hidden purchase contents. Original labels and independent '
             'pilot references remain preserved alongside separate coordinator adjudications.\n\n'
             'Use this as weak supervision after inspecting labels and class balance. '
             'It cannot establish production accuracy or resolve the contents of a mixed-retailer purchase.\n')
    path = Path('research/DELAWARE_LABELED_DATASET_2026-10-17.md')
    path.write_text(text)
    print(path)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['status','freeze','report'])
    parser.add_argument('--spawned', type=int, help='Coordinator records confirmed sequential worker spawns')
    args = parser.parse_args()
    {'status': lambda: status(args.spawned), 'freeze': freeze, 'report': report}[args.phase]()
