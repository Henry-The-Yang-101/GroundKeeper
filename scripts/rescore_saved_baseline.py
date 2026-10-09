"""Repair only Markdown JSON wrappers; preserve original strict-run evidence."""
import json,shutil
from pathlib import Path
from groundkeeper.policy import parse_answer,safe_prediction
from groundkeeper.metrics import evaluate
root=Path('.local/finetune');original=root/'baseline_report.json'
if (root/'baseline_strict_report.json').exists():raise SystemExit('Baseline already rescored; refusing to overwrite evidence')
shutil.copyfile(original,root/'baseline_strict_report.json');shutil.copyfile(root/'baseline_predictions.jsonl',root/'baseline_strict_predictions.jsonl')
rows=[json.loads(s) for s in (root/'prepared/valid_records.jsonl').read_text().splitlines()]
preds=[json.loads(s) for s in (root/'baseline_predictions.jsonl').read_text().splitlines()]
assert [r['id'] for r in rows]==[r['id'] for r in preds]
invalid=0;fixed=0
for r in preds:
 try:r['prediction']=parse_answer(r['raw'])
 except (ValueError,TypeError):invalid+=1;r['prediction']=safe_prediction(r['raw'])
 fixed+=int(r['raw'].strip().startswith('```'))
answers=[r['prediction'] for r in preds];report=json.loads(original.read_text());report['metrics']=evaluate([r['answer'] for r in rows],answers)
for source in sorted({r['source'] for r in rows}):
 ix=[i for i,r in enumerate(rows) if r['source']==source]
 report['metrics'].setdefault('by_source',{})[source]=evaluate([rows[i]['answer'] for i in ix],[answers[i] for i in ix])
report.update(invalid_outputs=invalid,format_repaired_outputs=fixed,parser_revision='whole_JSON_fence_then_strict_schema',rescoring_note='Same raw generations, no model/prompt changes; original strict evidence preserved.')
original.write_text(json.dumps(report,indent=2));(root/'baseline_predictions.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in preds));print({k:report['metrics'][k] for k in ['category_accuracy','type_accuracy','joint_accuracy','macro_f1_supported_categories']});print('invalid',invalid,'fenced',fixed)
