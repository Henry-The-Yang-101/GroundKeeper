"""Package only the bounded probe; this is NOT an approved production model."""
import hashlib,json,shutil
from pathlib import Path
from groundkeeper.runtime import LocalCategorizer
from groundkeeper.policy import validate_answer
root=Path('.local/finetune');dest=root/'package-probe'
if dest.exists():raise SystemExit('Refusing to overwrite an existing package')
(dest/'model').mkdir(parents=True);(dest/'adapters').mkdir()
for p in (root/'models/qwen35-text').iterdir():
 if p.is_file():shutil.copyfile(p,dest/'model'/p.name)
for name in ['adapters.safetensors','adapter_config.json']:
 shutil.copyfile(root/'adapters/probe'/name,dest/'adapters'/name)
shutil.copyfile(Path('experiments/finetune/LABELING_POLICY.md'),dest/'LABELING_POLICY.md')
(dest/'EXPERIMENTAL.txt').write_text('Bounded QLoRA probe only. No real validation. All model predictions require review. Do not replace an approved model. Base checkpoint remains available for rollback.\n')
runtime=LocalCategorizer(dest/'model',dest/'adapters')
inputs=[{'description':s,'direction':d,'currency':c} for s,d,c in [('TIM HORTONS','debit','CAD'),('STARBUCKS','debit','USD'),('AMAZON MKTP','debit','USD'),('PAYROLL SALARY','credit','CAD'),('INTERAC TO ALEX','debit','CAD')]]
smoke=[validate_answer(runtime.suggest(r)) for r in inputs]
assert all(r['review'] for r in smoke)
files={str(p.relative_to(dest)):{'bytes':p.stat().st_size,'sha256':hashlib.file_digest(p.open('rb'),'sha256').hexdigest()} for p in dest.rglob('*') if p.is_file()}
manifest={'files':files,'model_revision':'32f3e8ecf65426fc3306969496342d504bfa13f3','runtime':'groundkeeper.runtime.LocalCategorizer','thinking':False,'release_status':'probe_only_not_production','smoke':smoke,'rollback':str(root/'models/qwen35-text')}
(dest/'manifest.json').write_text(json.dumps(manifest,indent=2))
total=sum(p.stat().st_size for p in dest.rglob('*') if p.is_file())
report={'total_bytes':total,'limit_decimal_bytes':3_000_000_000,'under_limit':total<3_000_000_000,'includes':['base_weights','tokenizer','chat_template','configs','adapter','policy','manifest'],'smoke_count':len(smoke),'all_smoke_schema_valid':True,'all_smoke_review_required':True,'package':str(dest),'status':'probe_only'}
(root/'package_report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2));assert report['under_limit']
