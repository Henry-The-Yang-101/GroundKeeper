"""Build coverage-aware v2 partitions without reading the already-used v1 test.

Use --draft to prepare the independent label audit. Freezing requires a completed
audit and refuses to overwrite an existing prepared dataset.
"""
import argparse
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

from groundkeeper.policy import CATEGORIES, TYPES, validate_answer, validate_input
from groundkeeper.policy_v2 import messages_v2
from scripts.full_common import read_rows, sha256, write_json
from scripts.prepare_training import canonical_group, key
from scripts.prepare_v2_candidates import BANKS

ROOT = Path('.local/finetune')
OUT = ROOT / 'v2'
PUBLIC = Path('experiments/finetune/v2')
FIELDS = {'id','type','category','review','merchant_group','evidence','disposition'}
BANK_ALIASES = {key(name): entity for _, name, entity in
                (line.split('|') for line in BANKS.splitlines())}
BANK_ALIASES.update({key(entity): entity for entity in BANK_ALIASES.values()})
BANK_ALIASES.update({'chasebank':'jpmorganchase','jpmorganchasebank':'jpmorganchase',
    'royalbankofcanada':'rbc','tdbank':'td','tddirectinvesting':'td',
    'bmo':'bmo','bankofnovascotia':'scotiabank',
    'alliantcu':'alliantcreditunion','navyfederal':'navyfederalcreditunion',
    'wellsfargobank':'wellsfargo','capitalonebank':'capitalone',
    'allybank':'allybank','usaa':'usaa','americanexpress':'americanexpress'})
EXTRA_ALIASES = {'enterprise':'enterpriseholdings','enterpriserentacar':'enterpriseholdings',
    'avis':'avisbudgetgroup','avisbudget':'avisbudgetgroup','budget':'avisbudgetgroup',
    'avisbudgetgroup':'avisbudgetgroup',
    'metropcs':'tmobile','metrobytmobile':'tmobile','tmobileus':'tmobile',
    'wholefoodsmarket':'amazon','trampolinepark':'generic:trampolinepark',
    'generic:trampolinepark':'generic:trampolinepark',
    'generic:brokeragetransaction':'generic:brokerage',
    'generic:waterutility':'generic:municipalwater',
    # Conservative textual brand/family aliases identified in the blind-label
    # group audit. Fuzzy similarity alone must never merge distinct entities.
    'summithealthcareco':'summithealthcare','escaperoomco':'escaperoom',
    'americanwatergas':'americanwater','bjswholesale':'bjswholesaleclub',
    'lasertagcom':'generic:lasertag','lasertag':'generic:lasertag',
    'hardrockbet':'hardrock','lincolnproperty':'lincolnpropertycompany',
    'paddlenet':'paddle','orangetheory':'orangetheoryfitness',
    'tiktokshop':'tiktok','socialsecurity':'socialsecurityadministration',
    'homesite':'homesiteinsurance','rallys':'checkersrallys',
    'caesarssportsbook':'caesars','patelcocreditunion':'patelco',
    'fubotv':'fubo','carnivalcruiseline':'carnival',
    'stateofcaliforniafound':'stateofcalifornia',
    'pacificconsultingco':'pacificconsulting','municipalwater':'generic:municipalwater',
    'frontier':'frontierairlines','unitedwholesale':'unitedwholesalemortgage',
    'donehealthcorp':'donehealth','sportsclips':'sportclips','aquariumllc':'aquarium',
    'unemploymentinsuranceco':'unemploymentinsurance','dunkindonuts':'dunkin',
    'bishopscutcom':'bishopscut','casellawaste':'casella',
    'childtaxcredit':'generic:childtaxcredit','escaperoom':'generic:escaperoom',
    'generic:golfdrivingrange':'generic:drivingrange',
    'generic:homewarrantyinsurance':'generic:homewarranty',
    'generic:municipalwaterandphoneservice':'generic:municipalwater',
    'generic:restaurantmeal':'generic:restaurant','generic:restaurantpurchase':'generic:restaurant',
    'generic:statecomptrollercredit':'statecomptroller',
    'generic:unclearpearsontransaction':'pearson',
    'generic:unidentifiedmerchanttransaction':'generic:unidentifiedmerchant',
    'generic:unknownmerchantpurchase':'generic:unknownmerchant',
    'thehartford':'hartford','horizontechco':'horizontech',
    'nationstarmortgage':'nationstar','sunpowersolar':'sunpower',
    'thewallstreetjournal':'wallstreetjournal','mintmobile':'tmobile',
    'visible':'verizon','drizly':'uber'}

# Literal merchant text was obscured by an initial generic/processor group.
# These repair split metadata only; the independent audit handles decisions.
ROW_GROUP_OVERRIDES={'ddt-60459':'fastspring','ddt-65938':'visible'}


def normalized_group(group):
    value = ('generic:' + key(group.split(':',1)[1])
             if group.startswith(('generic:','unknown:')) else key(group))
    # Synthetic physician names recur with changed specialties; withholding a
    # specialty while teaching the same surname is not an unseen-provider test.
    doctor=re.fullmatch(r'dr([a-z]+?)(?:familymedicine|orthopedics|physicaltherapy|cardiology|optometry|dermatology|pediatrics|psychiatry|dentistry|dental)',value)
    if doctor:
        value='dr'+doctor[1]
    seen=set()
    while value not in seen:
        seen.add(value)
        target=EXTRA_ALIASES.get(value,BANK_ALIASES.get(value,value))
        if target==value:
            return value
        value=target
    raise ValueError('Cycle in merchant aliases')


def entity_group(row, label):
    if row['id'] in ROW_GROUP_OVERRIDES:
        return normalized_group(ROW_GROUP_OVERRIDES[row['id']])
    if row.get('split_entity'):
        return normalized_group(row['split_entity'])
    # Recognizable banks take precedence over vague purpose-only labels. Avoid
    # identifying a short bank acronym inside an unrelated merchant word.
    text = row['input']['description'].casefold()
    found = set()
    for name, entity in BANK_ALIASES.items():
        if len(name) >= 5 and name in key(text):
            found.add(entity)
        elif len(name) < 5 and re.search(r'(?<!\w)' + re.escape(name) + r'(?!\w)', text):
            found.add(entity)
    if len(found) == 1:
        return found.pop()
    return normalized_group(canonical_group(label, row['input']))


def description_key(row):
    # Case, whitespace, punctuation and changing reference numbers do not create
    # independent examples. Direction/currency cannot excuse cross-split copies.
    return re.sub(r'\d+', '#', key(row['input']['description']))


def load_labels():
    candidates = read_rows(OUT / 'candidates.jsonl')
    expected_hash = json.loads((PUBLIC / 'candidate_report.json').read_text())['candidate_sha256']
    if sha256(OUT / 'candidates.jsonl') != expected_hash:
        raise ValueError('Candidate pool changed after blinding')
    labels = []
    for packet in range(116):
        inputs = read_rows(OUT / f'packets/batch_{packet:03d}.jsonl')
        rows = read_rows(OUT / f'labels/batch_{packet:03d}.jsonl')
        if len(rows) != 25 or [r['id'] for r in rows] != [r['id'] for r in inputs]:
            raise ValueError(f'Packet {packet} incomplete or reordered')
        for row in rows:
            if set(row) != FIELDS or row['disposition'] not in ('keep','reject'):
                raise ValueError(f'Invalid annotation {row.get("id")}')
            if not all(isinstance(row[k],str) and row[k].strip() for k in ('merchant_group','evidence')):
                raise ValueError(f'Empty evidence/group {row["id"]}')
            validate_answer({k:row[k] for k in ('type','category','review')})
            labels.append({**row, 'packet':packet,'reviewer_model':'gpt-6-luna',
                           'reasoning_effort':'xhigh','label_status':'ai_reviewed_not_human'})
    if {r['id'] for r in labels} != {r['id'] for r in candidates} or len(labels) != 2900:
        raise ValueError('Candidate/annotation coverage mismatch')
    return candidates, labels


def allocate(rows, manifest):
    """Merchant anchors and connected duplicates win over hash allocation."""
    anchors = defaultdict(set)
    for entry in manifest:
        anchors[normalized_group(entry['group'])].add(entry['split'])
    for row in rows:
        if row.get('legacy_training'):
            anchors[row['merchant_group']].add('train')
        if row.get('planned_split'):
            anchors[row['merchant_group']].add(row['planned_split'])
    parent = {r['merchant_group']:r['merchant_group'] for r in rows}
    def find(group):
        while parent[group] != group:
            parent[group] = parent[parent[group]]
            group = parent[group]
        return group
    seen = {}
    for row in rows:
        desc, group = description_key(row), row['merchant_group']
        if desc in seen:
            a,b = sorted((find(group),find(seen[desc])))
            parent[b] = a
        else:
            seen[desc] = group
    combined = defaultdict(set)
    for group in parent:
        combined[find(group)].update(anchors[group])
    excluded, result = [], []
    old_test_groups = {normalized_group(r['group']) for r in manifest if r['split']=='test'}
    old_test_roots = {find(g) for g in old_test_groups if g in parent}
    old_hashes = {r['input_sha256'] for r in manifest if r['split']!='train'}
    for row in rows:
        group = find(row['merchant_group'])
        roles = combined[group]
        # Conflicting anchors cannot be fixed by moving an old training row into
        # evaluation: v1 already learned it. Drop the entire connected component.
        reason = ('v1_final_test_merchant' if group in old_test_roots else
                  'conflicting_partition_anchors' if len(roles)>1 else None)
        digest = hashlib.sha256(json.dumps(row['input'],sort_keys=True).encode()).hexdigest()
        if digest in old_hashes:
            reason = 'v1_heldout_exact_input'
        if reason:
            excluded.append({'id':row['id'],'reason':reason,'group':group})
            continue
        if roles:
            split = next(iter(roles))
        else:
            number = int(hashlib.sha256(('gk-v2:'+group).encode()).hexdigest(),16)%100
            split = 'train' if number<80 else 'valid' if number<90 else 'test'
        result.append({**row,'merchant_group':group,'split':split})
    return result, excluded


def cap_variants(rows):
    retained, excluded = [], []
    counts, combos, duplicates = Counter(), Counter(), {}
    # Keep useful legacy training evidence; add at most two examples of each
    # merchant/decision combination, not two examples across all bank purposes.
    for row in sorted(rows, key=lambda r:(not r.get('legacy_training',False),r['id'])):
        group = row['merchant_group']
        combo = (group, json.dumps(row['answer'],sort_keys=True))
        duplicate = (description_key(row),row['input']['direction'],row['input']['currency'])
        reason = None
        if duplicate in duplicates:
            prior = duplicates[duplicate]
            if prior['answer'] != row['answer']:
                raise ValueError(f'Conflicting normalized duplicates need audit: {prior["id"]}, {row["id"]}')
            reason = 'normalized_duplicate'
        elif counts[group]>=24:
            reason = 'merchant_cap_24'
        elif not row.get('legacy_training') and combos[combo]>=2:
            reason = 'merchant_decision_cap_2'
        if reason:
            excluded.append({'id':row['id'],'reason':reason})
            continue
        duplicates[duplicate] = row
        counts[group] += 1
        combos[combo] += 1
        retained.append(row)
    return retained, excluded


def coverage(partitions, enforce=True):
    counts = {}
    failures = []
    for split, rows in partitions.items():
        types = Counter(r['answer']['type'] for r in rows)
        cats = Counter(r['answer']['category'] or '__none__' for r in rows)
        counts[split] = {'n':len(rows),'types':dict(types),'categories':dict(cats),
            'sources':dict(Counter(r['source'] for r in rows)),
            'currencies':dict(Counter(r['input']['currency'] for r in rows)),
            'merchant_groups':len({r['merchant_group'] for r in rows})}
        type_min, cat_min = (24,25) if split=='train' else (4,2)
        for typ in TYPES:
            if types[typ]<type_min:
                failures.append(f'{split} type {typ}: {types[typ]} < {type_min}')
        for cat in CATEGORIES:
            if cats[cat]<cat_min:
                failures.append(f'{split} category {cat}: {cats[cat]} < {cat_min}')
    if enforce and failures:
        raise ValueError('Coverage gate failed: ' + '; '.join(failures))
    return counts, failures


def write_rows(path, rows):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(''.join(json.dumps(r,ensure_ascii=False,sort_keys=True)+'\n' for r in rows))


def build(draft=False):
    candidates, labels = load_labels()
    source = {r['id']:r for r in candidates}
    fixes = json.loads((PUBLIC/'training_adjudications.json').read_text())
    consistency_path=PUBLIC/'consistency_adjudications.json'
    consistency=json.loads(consistency_path.read_text()) if consistency_path.exists() else {}
    fixes={**fixes,**consistency}
    audit_path = PUBLIC/'new_label_audit.json'
    audit = json.loads(audit_path.read_text()) if audit_path.exists() else {}
    if not draft:
        from scripts.summarize_v2_audit import verify_completed
        audit = verify_completed()
    overrides = {**consistency,**audit.get('adjudications',{})}
    accepted, excluded = [], []
    old = read_rows(ROOT/'prepared/train_records.jsonl')
    for row in old:
        fix = fixes.get(row['id'],{})
        if fix.get('reject'):
            excluded.append({'id':row['id'],'reason':'v2_policy_audit_reject'})
            continue
        row = {**row,'answer':fix.get('answer',row['answer']),'legacy_training':True}
        row['merchant_group'] = entity_group(row,row)
        accepted.append(row)
    for label in labels:
        row = source[label['id']]
        change = overrides.get(label['id'],{})
        if label['disposition']=='reject' or change.get('reject'):
            excluded.append({'id':row['id'],'reason':'new_label_rejected'})
            continue
        answer = change.get('answer',{k:label[k] for k in ('type','category','review')})
        group_label = {**label,'merchant_group':change.get('merchant_group',label['merchant_group'])}
        accepted.append({**row,'answer':answer,'merchant_group':entity_group(row,group_label),
            'evidence':label['evidence'],'label_status':'ai_reviewed_not_human'})
    for row in accepted:
        validate_input(row['input']); validate_answer(row['answer'])
    manifest = read_rows('experiments/finetune/split_manifest.jsonl')
    # Legacy validation is available for grouping checks. Derive any clearer
    # bank identity from it without touching the sealed/already-used v1 test.
    for row in read_rows(ROOT/'prepared/valid_records.jsonl'):
        manifest.append({'id':row['id'],'group':entity_group(row,row),'split':'valid',
            'input_sha256':hashlib.sha256(json.dumps(row['input'],sort_keys=True).encode()).hexdigest()})
    allocated, dropped = allocate(accepted,manifest)
    excluded += dropped
    retained, dropped = cap_variants(allocated)
    excluded += dropped
    partitions = {s:sorted([r for r in retained if r['split']==s],key=lambda r:r['id'])
                  for s in ('train','valid','test')}
    counts, failures = coverage(partitions,enforce=not draft)
    groups = {s:{r['merchant_group'] for r in rows} for s,rows in partitions.items()}
    for a,b in [('train','valid'),('train','test'),('valid','test')]:
        if groups[a]&groups[b]:
            raise ValueError('Merchant leakage')
        if {description_key(r) for r in partitions[a]} & {description_key(r) for r in partitions[b]}:
            raise ValueError('Normalized description leakage')
    out = OUT/('draft' if draft else 'prepared')
    if out.exists() and not draft:
        raise FileExistsError('Frozen dataset cannot be replaced')
    out.mkdir(parents=True,exist_ok=True)
    for split, rows in partitions.items():
        target = out/f'{split}_records.jsonl'
        write_rows(target,rows)
        if split=='test':
            target.chmod(0o600)
        elif not draft:
            write_rows(out/f'{split}.jsonl',[{'messages':messages_v2(r['input'],r['answer'])} for r in rows])
    report = {'phase':'draft' if draft else 'frozen','split_counts':counts,
        'coverage_failures':failures,'excluded':dict(Counter(r['reason'] for r in excluded)),
        'real_transactions':0,'human_labels':0,'legacy_validation_n':116,
        'legacy_final_test_accessed':False,'source_candidate_sha256':sha256(OUT/'candidates.jsonl'),
        'policy_sha256':sha256(PUBLIC/'POLICY_ADDITIONS.md'),
        'preparation_code_sha256':sha256(__file__),
        'annotation_packet_hashes':{p.name:sha256(p) for p in sorted((OUT/'labels').glob('batch_*.jsonl'))},
        'new_audit_sha256':sha256(audit_path) if audit_path.exists() else None,
        'consistency_adjudications_sha256':sha256(consistency_path) if consistency_path.exists() else None,
        'files':{s:sha256(out/f'{s}_records.jsonl') for s in partitions},
        'caps':'24 per merchant; 2 per new merchant/decision; retained legacy variants exempt from per-decision cap',
        'limitations':['synthetic text and AI labels','authored wording is not real bank distribution',
                      'coverage counts do not establish performance','no real calibration']}
    write_json(out/'dataset_report.json',report)
    write_rows(out/'excluded.jsonl',excluded)
    if not draft:
        write_rows(PUBLIC/'public_annotations.jsonl',labels)
        write_rows(PUBLIC/'split_manifest.jsonl',[{'id':r['id'],'group':r['merchant_group'],
            'split':r['split'],'input_sha256':hashlib.sha256(json.dumps(r['input'],sort_keys=True).encode()).hexdigest()}
            for r in retained])
        write_json(PUBLIC/'dataset_report.json',report)
    print(json.dumps(report,indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--draft',action='store_true')
    build(parser.parse_args().draft)
