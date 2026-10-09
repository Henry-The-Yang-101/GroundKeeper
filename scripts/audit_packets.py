"""Deterministic difficult-case selection before blind labeling."""
import csv,json,re,random
from pathlib import Path
rows=list(csv.DictReader(open('.local/finetune/sources/DoDataThings/transactions-synthetic.csv')))
patterns=[r'payment refund',r'\[credit\].*(fee|cvs|carnival|whole)',r'zelle',r'venmo',r'mortgage',r'principal',r'monthly installments',r'cvs',r'costco',r'apple.com|apple tv|applecard',r'google',r'fitness',r'subscription',r'paypal inst xfer',r'gift|donation',r'tax|dmv',r'shopping|amazon',r'uber',r'cash|atm',r'insurance|premium']
rng=random.Random(20261008); rng.shuffle(rows); picked=[]; seen=set()
for pat in patterns:
 for r in [r for r in rows if re.search(pat,r['description'],re.I)][:3]:
  if r['description'] not in seen:
   seen.add(r['description']); picked.append(r)
for r in rows:
 if len(picked)>=60:break
 if r['description'] not in seen:seen.add(r['description']);picked.append(r)
root=Path('.local/finetune/audit');root.mkdir(parents=True,exist_ok=True)
for i in range(3):
 with (root/f'difficult_{i}.jsonl').open('w') as f:
  for j,r in enumerate(picked[i*20:(i+1)*20]):f.write(json.dumps({'id':f'audit-{i*20+j:03}',**r})+'\n')
print('Prepared 3 difficult-case packets of 20 public examples')
