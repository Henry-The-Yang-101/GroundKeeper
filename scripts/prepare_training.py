"""Validate immutable annotations, apply adjudications, cap variants, seal splits."""
import json,hashlib,re,random
from collections import Counter,defaultdict
from pathlib import Path
from groundkeeper.policy import validate_answer,validate_input,messages

ROOT=Path('.local/finetune');PUBLIC=Path('experiments/finetune')
def read(path):return [json.loads(x) for x in Path(path).read_text().splitlines() if x.strip()]
def write(path,rows):Path(path).write_text(''.join(json.dumps(r,ensure_ascii=False,sort_keys=True)+'\n' for r in rows))
def key(s):return re.sub(r'[^a-z0-9]','',s.casefold())
PARENTS={
 'amazon':['amazon','amazonaws','aws','wholefoodsmarket','wholefoods','zappos','twitch','audible','kindle'],
 'google':['google','fitbit','youtube','googlefiber'],
 'meta':['meta','metaplatforms','facebook','instagram'],
 'expedia':['expedia','expediagroup','hotwire','travelocity','hotelscom','vrbo'],
 'uber':['uber','ubereats','ubertrip'],
 'kroger':['kroger','food4less','ralphs','fredmeyer'],
 'albertsons':['albertsons','safeway','shaws'],
 'walmart':['walmart','samsclub'],
 'matchgroup':['matchcom','tinder','hinge'],
 'booking':['booking','bookingcom','kayak','priceline'],
 'brilliant':['brilliant','brilliantorg'],
 'ranch99':['99ranchmarket','ranch99'],
 'cox':['cox','coxcommunications'],
 'relatedcompanies':['relatedcompanies','relatedcos'],
 'marketbasket':['marketbasket','marketbas'],
 'newyorktimes':['thenewyorktimes','theathletic','nyt'],
 'sony':['sony','sonyplaystation','playstation'],
 'starlink':['starlink','spacex'],
 'enterprise':['enterprise','enterpriseholdingsenterpriserentacar','enterpriserentacar','nationalcarrental','alamo'],
 'hertz':['hertz','dollarrentacar','thrifty'],
 'avis':['avis','budget'],
 'intuit':['intuit','creditkarma','mint'],
 'yum':['tacobell','kfc','pizzahut'],
 'ckr':['carlsjr','hardees'],
 'groceryoutlet':['groceryoutlet','grocoutlt'],
 'stateofcalifornia':['stateofcalifornia','stateofcaliforniaco'],
 'loblaw':['loblaw','loblawcompanies','loblawcompaniesloblaws','loblawcompaniesshoppersdrugmart','loblaws','loblawshoppersdrugmart','shoppersdrugmart','shoppers'],
 'apple':['apple','icloud','appleicloud'],
 'microsoft':['microsoft','github','githubcopilot'],
 'dmv':['dmv','californiadmv','statedmv'],
 'valve':['valve','valvesteam','steam'],
 'td':['td','tdtdinsurance'],
 'cibc':['cibc','cibcvisa'],
 'governmentofontario':['governmentofontario','governmentofontariodriverlicensing'],
 'governmentofcanada':['governmentofcanadapassportprogram','governmentofcanadacanadachildbenefit','canadarevenueagency'],
}
ALIASES={child:parent for parent,children in PARENTS.items() for child in children}
def canonical_group(label,inputs):
    group=label['merchant_group'].casefold().strip()
    if group.startswith(('google/','google /','paypal /','paypal/')):group=group.split('/')[-1].strip()
    clean=key(group)
    # Generic names/rails do not distinguish merchants; keep families together.
    if group.startswith(('generic:','unknown:')) or clean in {'unknown','zelle','venmo','cashapp','danielpark','thomaschen','interac'}:
        d=inputs['description'].casefold()
        if re.search(r'zelle|venmo|cash app|interac',d):return 'generic:p2p'
        if re.search(r'mortgage|mtg|escrow',d):return 'generic:mortgage'
        if re.search(r'installment|loan|principal',d):return 'generic:loan'
        if re.search(r'property tax',d):return 'generic:property-tax'
        if re.search(r'dmv',d):return 'generic:dmv'
        if re.search(r'shipping',d):return 'generic:shipping'
        if re.search(r'fee|surcharge|service charge|interest charge',d):return 'generic:financial-fee'
        if re.search(r'climbing gym',d):return 'generic:climbing-gym'
        if re.search(r'trampoline park',d):return 'generic:trampoline-park'
        if re.search(r'laser tag',d):return 'generic:laser-tag'
        if re.search(r'theme park',d):return 'generic:theme-park'
        if re.search(r'golf course',d):return 'generic:golf-course'
        if re.search(r'us mobile',d):return 'usmobile'
        if re.search(r'payroll|benefit',d):return 'generic:earnings'
        if re.search(r'dmv',d):return 'generic:dmv'
        if re.search(r'transfer|deposit|withdraw|payment|adjustment|statement credit',d):return 'generic:account-movement'
        return 'generic:'+key(group.split(':')[-1])
    return ALIASES.get(clean,clean)

def main():
    all_rows=read(ROOT/'selected.jsonl')+read(ROOT/'canadian_selected.jsonl')
    source={r['id']:r for r in all_rows};annotations=[]
    for i in range(38):
        packet=read(ROOT/f'packets/batch_{i:03d}.jsonl')
        labels=read(ROOT/f'labels/batch_{i:03d}.jsonl')
        assert len(labels)==25 and [r['id'] for r in labels]==[r['id'] for r in packet],f'Packet {i} coverage'
        for r in labels:
            assert set(r)=={'id','type','category','review','merchant_group','evidence','disposition'}
            assert r['disposition'] in ('keep','reject') and r['evidence']
            assert isinstance(r['merchant_group'],str) or r['id'] in {'ddt-57689','ddt-55446'}
            annotations.append({**r,'reviewer_model':'gpt-6-luna','reasoning_effort':'inherited_default' if i<9 else 'xhigh','packet':i,'label_status':'ai_reviewed_not_human'})
    assert len({a['id'] for a in annotations})==len(all_rows)==950
    manual=json.loads((PUBLIC/'adjudications.json').read_text()) if (PUBLIC/'adjudications.json').exists() else {}
    fixes=[];accepted=[];excluded=[]
    for label in annotations:
        r=source[label['id']]
        if label['merchant_group'] is None:
            fixes.append({'id':r['id'],'old_merchant_group':None,'reason':'Missing group repaired conservatively from public description.'})
            label={**label,'merchant_group':'clear' if r['id']=='ddt-57689' else 'swimmingpool'}
        answer={k:label[k] for k in ('type','category','review')}
        if answer['type']=='unknown' and answer['category'] is None:
            fixes.append({'id':r['id'],'old':answer.copy(),'reason':'Unknown output schema clarification'});answer.update(category='other',review=True)
        if r['id'] in manual:
            fixes.append({'id':r['id'],'old':answer.copy(),'reason':manual[r['id']]['reason']});answer.update(manual[r['id']]['answer'])
        if answer['category'] == 'uncategorized' or (answer['type'] in ('expense', 'refund', 'unknown') and answer['category'] is None):
            fixes.append({'id':r['id'],'old':answer.copy(),'reason':'Legacy missing category mapped to Other for current training policy'})
            answer.update(category='other',review=True)
        if answer['category'] == 'other': answer['review'] = True
        validate_answer(answer);validate_input(r['input'])
        if label['disposition']=='reject':excluded.append({'id':r['id'],'reason':'labeler_rejected'});continue
        accepted.append({**r,'answer':answer,'merchant_group':canonical_group(label,r['input']),'evidence':label['evidence'],'label_status':'ai_reviewed_not_human'})
    # Conservatively unite any cross-group identical descriptions (direction can
    # vary, but does not excuse split leakage) and canonical parent chain aliases.
    parent={r['merchant_group']:r['merchant_group'] for r in accepted}
    def find(a):
        while parent[a]!=a:parent[a]=parent[parent[a]];a=parent[a]
        return a
    def union(a,b):
        x,y=sorted((find(a),find(b)));parent[y]=x
    seen_desc={}
    for r in accepted:
        d=key(r['input']['description']);g=r['merchant_group']
        if d in seen_desc:union(g,seen_desc[d])
        else:seen_desc[d]=g
    for r in accepted:r['merchant_group']=find(r['merchant_group'])
    # Prefer varied directions/purposes within a merchant and cap all variants.
    rng=random.Random(20261008);rng.shuffle(accepted)
    counts=Counter();seen_inputs={};retained=[]
    for r in accepted:
        d=json.dumps(r['input'],sort_keys=True);g=r['merchant_group']
        if d in seen_inputs:
            prior=seen_inputs[d]
            assert prior['answer']==r['answer'],f'Conflicting duplicate labels: {prior["id"]} / {r["id"]}'
            excluded.append({'id':r['id'],'reason':'duplicate_input'});continue
        seen_inputs[d]=r
        if counts[g]>=6:excluded.append({'id':r['id'],'reason':'merchant_variant_cap_6'});continue
        counts[g]+=1;retained.append(r)
    # One fixed hash split; no retries based on model scores or class coverage.
    def split(g):
        v=int(hashlib.sha256(('gk-split-v1:'+g).encode()).hexdigest(),16)%100
        return 'train' if v<80 else 'valid' if v<90 else 'test'
    partitions={s:sorted([r for r in retained if split(r['merchant_group'])==s],key=lambda r:r['id']) for s in ('train','valid','test')}
    groups={s:{r['merchant_group'] for r in rows} for s,rows in partitions.items()}
    assert not (groups['train']&groups['valid'] or groups['train']&groups['test'] or groups['valid']&groups['test'])
    out=ROOT/'prepared';out.mkdir(exist_ok=True)
    for s,rows in partitions.items():
        target=out/f'{s}_records.jsonl' if s!='test' else ROOT/'sealed_test_records.jsonl'
        write(target,rows)
        if s!='test':write(out/f'{s}.jsonl',[{'messages':messages(r['input'],r['answer'])} for r in rows])
        else:target.chmod(0o600)
    # Source rows stay local. Public annotations contain source IDs and labels,
    # enabling deterministic reconstruction from pinned public downloads.
    write(PUBLIC/'public_annotations.jsonl',annotations);write(PUBLIC/'annotation_adjustments.jsonl',fixes)
    manifest=[{'id':r['id'],'group':r['merchant_group'],'split':s,'input_sha256':hashlib.sha256(json.dumps(r['input'],sort_keys=True).encode()).hexdigest()} for s,rows in partitions.items() for r in rows]
    write(PUBLIC/'split_manifest.jsonl',manifest);write(ROOT/'excluded.jsonl',excluded)
    report={'selected':len(all_rows),'raw_labeled':len(annotations),'retained':len(retained),'excluded':dict(Counter(r['reason'] for r in excluded)),'adjudicated_count':len(fixes),'source_audit_counts':dict(Counter(r['source_category'] for r in all_rows if r['source_category'])),'source_retained':dict(Counter(r['source'] for r in retained)),'policy_sha256':hashlib.sha256((PUBLIC/'LABELING_POLICY.md').read_bytes()).hexdigest(),'split_counts':{s:len(r) for s,r in partitions.items()},'group_counts':{s:len(g) for s,g in groups.items()},'split_category_counts':{s:dict(Counter(r['answer']['category'] or '__none__' for r in rows)) for s,rows in partitions.items()},'sealed_test_sha256':hashlib.sha256((ROOT/'sealed_test_records.jsonl').read_bytes()).hexdigest(),'real_reviewed_transactions':0,'human_labels':0,'augmentation':'none','fuzzy_calibration':'not_available'}
    (PUBLIC/'dataset_report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
if __name__=='__main__':main()
