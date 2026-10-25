"""Pinned public expansion plus explicitly authored US/Canadian coverage seeds.

This creates INPUTS ONLY. Every row needs independent blind labeling. Entity and
template metadata are for leakage controls, never model features or gold labels.
"""
import csv
import hashlib
import json
import random
import re
from collections import defaultdict, Counter
from pathlib import Path

ROOT = Path('.local/finetune')
OUT = ROOT / 'v2'
PUBLIC = Path('experiments/finetune/v2')

BANKS = '''USD|BANK OF AMERICA|bankofamerica
USD|CITIBANK|citibank
USD|US BANK|usbank
USD|NAVY FEDERAL CREDIT UNION|navyfederalcreditunion
USD|ALLIANT CREDIT UNION|alliantcreditunion
USD|CHASE|jpmorganchase
USD|PNC BANK|pnc
USD|TRUIST BANK|truist
USD|REGIONS BANK|regionsbank
USD|FIFTH THIRD BANK|fifththirdbank
USD|HUNTINGTON BANK|huntingtonbank
USD|KEYBANK|keybank
USD|CITIZENS BANK|citizensbank
USD|PENFED CREDIT UNION|penfedcreditunion
USD|M AND T BANK|mandtbank
USD|SYNCHRONY BANK|synchronybank
CAD|RBC ROYAL BANK|rbc
CAD|TD CANADA TRUST|td
CAD|BANK OF MONTREAL|bmo
CAD|CIBC|cibc
CAD|SCOTIABANK|scotiabank
CAD|NATIONAL BANK OF CANADA|nationalbankofcanada
CAD|DESJARDINS|desjardins
CAD|LAURENTIAN BANK|laurentianbank
CAD|ATB FINANCIAL|atbfinancial
CAD|MERIDIAN CREDIT UNION|meridiancreditunion
CAD|VANCITY CREDIT UNION|vancity
CAD|COAST CAPITAL SAVINGS|coastcapital
CAD|SERVUS CREDIT UNION|servus
CAD|ALTERNA SAVINGS|alterna
CAD|DUCA CREDIT UNION|duca
CAD|CONEXUS CREDIT UNION|conexus'''

# Independent wording families for each partition. Explicit type evidence is
# intentionally shared as a concept; exact template families are held apart.
BANK_PURPOSES = [
    ('debit', 'MONTHLY ACCOUNT SERVICE FEE', 'BANKING SERVICE CHARGE FOR THIS MONTH', 'ACCOUNT MAINTENANCE FEE CHARGED'),
    ('credit', 'EMPLOYER PAYROLL SALARY DEPOSIT', 'WAGES FROM EMPLOYER CREDITED', 'SALARY PAYMENT RECEIVED FROM WORK'),
    ('credit', 'MERCHANT PURCHASE REFUND', 'RETURNED PURCHASE REFUND CREDIT', 'REFUND FOR AN EARLIER PURCHASE RECEIVED'),
    ('debit', 'TRANSFER BETWEEN MY OWN CHEQUING AND SAVINGS', 'MOVE FUNDS TO ANOTHER ACCOUNT OWNED BY ME', 'MY ACCOUNT TO MY OTHER ACCOUNT INTERNAL TRANSFER'),
    ('debit', 'PAYMENT TO MY CREDIT CARD BALANCE', 'REPAYMENT OF PERSONAL CREDIT CARD', 'CREDIT CARD BILL PAID FROM DEPOSIT ACCOUNT'),
    ('debit', 'LOAN PRINCIPAL ONLY REPAYMENT NO INTEREST', 'PAYMENT OF PRINCIPAL EXCLUDING ALL INTEREST', 'REDUCTION OF LOAN PRINCIPAL ONLY'),
    ('debit', 'ATM CASH WITHDRAWAL', 'CASH DISPENSED AT AUTOMATED TELLER', 'WITHDRAWAL OF PHYSICAL CASH AT ATM'),
    ('credit', 'ACCOUNT BALANCE CORRECTION ADJUSTMENT', 'POSTED BALANCE ADJUSTMENT CREDIT', 'BOOKKEEPING CORRECTION TO ACCOUNT BALANCE'),
    ('debit', 'E TRANSFER TO ALEX', 'PERSON TO PERSON PAYMENT TO SAM', 'PAYMENT SENT TO JORDAN PURPOSE UNSPECIFIED'),
]

PURPOSES = {
 'groceries': ('SUPERMARKET GROCERY PURCHASE', 'FOOD INGREDIENTS FROM GROCERY STORE', 'GROCERIES DELIVERED FROM SUPERMARKET'),
 'dining': ('RESTAURANT MEAL', 'PREPARED FOOD TAKEOUT ORDER', 'CAFE COFFEE AND SANDWICH'),
 'local_transport': ('LOCAL BUS FARE', 'CITY TRANSIT TICKET', 'MUNICIPAL PARKING SESSION'),
 'vehicle': ('AUTOMOBILE REPAIR SERVICE', 'CAR ENGINE OIL CHANGE', 'GASOLINE FUEL FOR VEHICLE'),
 'housing': ('HOME PLUMBING REPAIR', 'RESIDENTIAL FURNACE REPAIR', 'RENT FOR MY APARTMENT'),
 'utilities': ('HOUSEHOLD WASTE COLLECTION BILL', 'MOBILE PHONE SERVICE BILL', 'HOME INTERNET SERVICE CHARGE'),
 'shopping': ('HOUSEHOLD CLEANING SUPPLIES PURCHASE', 'CLOTHING PURCHASE', 'FURNITURE AND HOUSEHOLD GOODS'),
 'medical': ('DENTAL EXAMINATION', 'PRESCRIPTION MEDICATION', 'OPTOMETRIST EYE EXAM'),
 'personal_care': ('HAIRCUT AND GROOMING', 'COSMETICS AND SKINCARE PURCHASE', 'NAIL SALON MANICURE'),
 'fitness': ('GYM MEMBERSHIP', 'SWIMMING LESSONS', 'ADULT SOCCER PARTICIPATION FEE'),
 'entertainment': ('CINEMA TICKET', 'LIVE MUSIC CONCERT ADMISSION', 'RECREATIONAL MINI GOLF ADMISSION'),
 'software': ('CLOUD FILE STORAGE SUBSCRIPTION', 'PRODUCTIVITY SOFTWARE LICENCE', 'WEB HOSTING SERVICE'),
 'education': ('COLLEGE TUITION PAYMENT', 'REQUIRED COURSE TEXTBOOK', 'LANGUAGE COURSE ENROLLMENT'),
 'travel': ('HOTEL OVERNIGHT ACCOMMODATION', 'INTERCITY RAIL TICKET', 'PASSENGER AIRLINE FLIGHT'),
 'insurance': ('HOME INSURANCE PREMIUM', 'LIFE INSURANCE POLICY PREMIUM', 'TENANT INSURANCE PREMIUM'),
 'financial': ('OVERDRAFT INTEREST CHARGE', 'CREDIT CARD ANNUAL FEE', 'LOAN INTEREST ONLY PAYMENT'),
 'taxes': ('MUNICIPAL PROPERTY TAX PAYMENT', 'GOVERNMENT PASSPORT RENEWAL FEE', 'PERSONAL INCOME TAX PAYMENT'),
 'gifts': ('CHARITABLE DONATION', 'BIRTHDAY GIFT FOR MY SISTER', 'DONATION TO COMMUNITY FOOD BANK'),
 'other': ('PET VETERINARY CONSULTATION', 'PERSONAL LEGAL REPRESENTATION FEE', 'STANDALONE COURIER SHIPPING FEE', 'GENERAL DRUGSTORE PURCHASE NO ITEM DETAILS', 'UNSPECIFIED DIGITAL APP STORE BILL', 'MIXED FUEL AND CONVENIENCE STORE PURCHASE'),
}


def main():
    candidate_path = OUT / 'candidates.jsonl'
    if candidate_path.exists():
        raise FileExistsError('Candidate pool is immutable; do not overwrite')
    OUT.mkdir(parents=True, exist_ok=True)
    packets = OUT / 'packets'
    packets.mkdir(exist_ok=True)
    old = [json.loads(x) for name in ['selected.jsonl','canadian_selected.jsonl']
           for x in (ROOT / name).read_text().splitlines()]
    old_ids = {x['id'] for x in old}
    seen = {re.sub(r'\s+', ' ', x['input']['description'].casefold()).strip() for x in old}
    anchors = {x['group']:x['split'] for x in map(json.loads, Path('experiments/finetune/split_manifest.jsonl').read_text().splitlines())}
    source = list(csv.DictReader((ROOT / 'sources/DoDataThings/transactions-synthetic.csv').open()))
    by_category = defaultdict(list)
    for index, row in enumerate(source):
        by_category[row['category']].append((index, row))
    rng = random.Random(20261009)
    candidates = []
    for category, rows in sorted(by_category.items()):
        rng.shuffle(rows)
        count = 0
        for index, row in rows:
            rid = f'ddt-{index:05d}'
            if rid in old_ids:
                continue
            raw = row['description']
            match = re.match(r'^\[(debit|credit)\]\s*', raw)
            description = raw[match.end():] if match else raw
            normalized = re.sub(r'\s+',' ',description.casefold()).strip()
            if normalized in seen:
                continue
            seen.add(normalized)
            candidates.append({'id':rid,'input':{'description':description,'direction':match[1] if match else 'unknown','currency':'USD'},
                'source':'DoDataThings/us-bank-transaction-categories-v2','source_revision':'3e8d052cb7b362fb1a04b6064d2331982553ea56',
                'source_row':index,'source_category':category,'origin':'public_synthetic','planned_split':None})
            count += 1
            if count == 100:
                break
        assert count == 100

    banks = [line.split('|') for line in BANKS.splitlines()]
    assert len(banks) == 32
    roles = {}
    for currency in ['CAD','USD']:
        novel = sorted([b for b in banks if b[0]==currency and b[2] not in anchors],
                       key=lambda b:hashlib.sha256(('v2-banks:'+b[2]).encode()).hexdigest())
        assert len(novel) >= 4
        for position, (_, _, entity) in enumerate(novel):
            roles[entity] = 'valid' if position < 2 else 'test' if position < 4 else 'train'
    for currency, name, entity in banks:
        role = anchors.get(entity, roles.get(entity, 'train'))
        assert entity not in anchors or role == 'train', 'Do not author on v1 held-out banks'
        family = {'train':0,'valid':1,'test':2}[role]
        for concept, (direction, *purposes) in enumerate(BANK_PURPOSES):
            for variant in range(2):
                purpose = purposes[family]
                if currency == 'USD':
                    purpose = purpose.replace('CHEQUING','CHECKING')
                description = f'{name} {purpose}' if variant==0 else f'{purpose} / {name} REF {concept+10}{variant+32}'
                candidates.append({'id':f'v2-bank-{entity}-{concept}-{variant}',
                    'input':{'description':description,'direction':direction,'currency':currency},
                    'source':'groundkeeper-authored-bank-coverage-v2','source_revision':'v2-seeds-1',
                    'origin':'authored_synthetic_not_real','source_category':None,
                    'split_entity':entity,'template_family':f'bank-family-{family}', 'planned_split':role})

    # Fictional provider names: explicit service descriptions carry the evidence.
    stems = ['ALDER','BIRCH','CEDAR','ELM','FERN','GROVE','HAZEL','IVY','JUNIPER','MAPLE',
             'NORTH','OAK','PINE','QUARRY','RIDGE','SPRUCE','TAMARACK','UPLAND','VALLEY','WILLOW',
             'ASPEN','BROOK','COVE','DALE','EAST','FIELD','GLEN','HILL','ISLAND','LAKE']
    for category_index, (category, purposes) in enumerate(PURPOSES.items()):
        count = 30 if category in ('financial','taxes','gifts','other') else 12
        for index in range(count):
            holdout = 4 if count==30 else 2
            role = 'test' if index < holdout else 'valid' if index < 2*holdout else 'train'
            family = {'train':0,'valid':1,'test':2}[role]
            currency = 'CAD' if index%2==0 else 'USD'
            name = f'{stems[index]} {stems[(index+category_index+3)%len(stems)]}'
            # Include concept in split entity only, not as a hidden input label.
            entity = f'authored-entity-{category}-{index}'
            for variant in range(2):
                purpose = purposes[family]
                description = f'{name} {purpose}' if variant==0 else f'{purpose} - {name} REF {index+41}'
                candidates.append({'id':f'v2-purpose-{category}-{index:02d}-{variant}',
                    'input':{'description':description,'direction':'debit','currency':currency},
                    'source':'groundkeeper-authored-purpose-coverage-v2','source_revision':'v2-seeds-1',
                    'origin':'authored_synthetic_fictional_provider','source_category':None,
                    'split_entity':entity,'template_family':f'purpose-family-{family}', 'planned_split':role})
    # Blind annotation IDs must not disclose the seed's intended category/type.
    authored_index = 0
    for row in candidates:
        if row['origin'].startswith('authored_'):
            row['id'] = f'v2-authored-{authored_index:04d}'
            authored_index += 1
    assert len(candidates)==2900 and len({x['id'] for x in candidates})==2900
    rng.shuffle(candidates)
    candidate_path.write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in candidates))
    for offset in range(0,len(candidates),25):
        packet = candidates[offset:offset+25]
        (packets/f'batch_{offset//25:03d}.jsonl').write_text(''.join(json.dumps({'id':x['id'],'input':x['input']})+'\n' for x in packet))
    report = {'candidates':len(candidates),'packets':len(candidates)//25,'packet_size':25,
              'sources':dict(Counter(x['source'] for x in candidates)),
              'authored_planned_splits':dict(Counter(x['planned_split'] for x in candidates if x['planned_split'])),
              'source_data_sha256':hashlib.sha256((ROOT/'sources/DoDataThings/transactions-synthetic.csv').read_bytes()).hexdigest(),
              'candidate_sha256':hashlib.sha256(candidate_path.read_bytes()).hexdigest(),
              'labels':'pending_blind_review','real_transactions':0,'human_labels':0,
              'note':'Candidates may be rejected or capped; do not call these accepted training examples.'}
    PUBLIC.mkdir(parents=True,exist_ok=True)
    (PUBLIC/'candidate_report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':
    main()
