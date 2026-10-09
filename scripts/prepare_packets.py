"""Select 50 distinct descriptions per source category, then blind the labelers."""
import csv,json,random,re,hashlib
from pathlib import Path
from collections import defaultdict,Counter
root=Path('.local/finetune');out=root/'packets';out.mkdir(exist_ok=True)
rows=list(csv.DictReader((root/'sources/DoDataThings/transactions-synthetic.csv').open()))
by=defaultdict(list)
for index,r in enumerate(rows): by[r['category']].append((index,r))
rng=random.Random(20261008); selected=[];seen=set()
for category,items in sorted(by.items()):
 rng.shuffle(items); n=0
 for index,r in items:
  key=re.sub(r'\s+',' ',r['description'].casefold()).strip()
  if key in seen:continue
  seen.add(key);desc=r['description'];m=re.match(r'^\[(debit|credit)\]\s*',desc)
  selected.append({'id':f'ddt-{index:05d}','input':{'description':desc[m.end():] if m else desc,'direction':m[1] if m else 'unknown','currency':'USD'},'source_category':category,'source':'DoDataThings/us-bank-transaction-categories-v2','source_revision':'3e8d052cb7b362fb1a04b6064d2331982553ea56','source_row':index,'origin':'public_synthetic'})
  n+=1
  if n==50:break
rng.shuffle(selected)
with (root/'selected.jsonl').open('w') as f:
 for r in selected:f.write(json.dumps(r)+'\n')
for i in range(0,len(selected),25):
 with (out/f'batch_{i//25:03d}.jsonl').open('w') as f:
  for r in selected[i:i+25]:f.write(json.dumps({'id':r['id'],'input':r['input']})+'\n')
print(json.dumps({'rows':len(selected),'packets':(len(selected)+24)//25,'counts':dict(Counter(r['source_category'] for r in selected))}))
