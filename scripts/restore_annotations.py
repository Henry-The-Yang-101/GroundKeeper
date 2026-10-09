"""Restore public ID-based annotations after downloading the pinned source."""
import json
from collections import defaultdict
from pathlib import Path
root=Path('.local/finetune/labels');root.mkdir(parents=True,exist_ok=True)
packets=defaultdict(list)
for line in Path('experiments/finetune/public_annotations.jsonl').read_text().splitlines():
 r=json.loads(line);packets[r['packet']].append({k:r[k] for k in ('id','type','category','review','merchant_group','evidence','disposition')})
for packet,rows in packets.items():
 path=root/f'batch_{packet:03d}.jsonl'
 if path.exists():
  existing=[json.loads(s) for s in path.read_text().splitlines()]
  if existing!=rows:raise SystemExit(f'Refusing to overwrite differing annotations: {path}')
 else:path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
print('Verified/restored',sum(map(len,packets.values())),'public annotations')
