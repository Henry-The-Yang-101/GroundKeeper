"""Drop vision weights using MLX-LM's native sanitizer; preserve 4-bit tensors."""
import json,shutil,hashlib
from pathlib import Path
import mlx.core as mx
from mlx_lm import load,generate
from mlx_lm.utils import save_model
from mlx_lm.sample_utils import make_sampler
from mlx.utils import tree_flatten
src=Path('.local/finetune/models/qwen35-original');dst=Path('.local/finetune/models/qwen35-text')
if dst.exists():raise SystemExit('Refusing to overwrite existing text checkpoint')
model,tok,cfg=load(str(src),return_config=True)
weights=dict(tree_flatten(model.parameters()))
assert not any('vision' in k or 'visual' in k for k in weights)
assert cfg['quantization']['bits']==4
dst.mkdir();save_model(dst,model)
# Make disabled thinking the template default for native trainer and production.
template='{% set enable_thinking = false %}\n'+(src/'chat_template.jinja').read_text()
tok.chat_template=template;tok.save_pretrained(dst)
(dst/'chat_template.jinja').write_text(template)
for key in ['vision_config','vision_start_token_id','vision_end_token_id','image_token_id','video_token_id']:
 cfg.pop(key,None)
(dst/'config.json').write_text(json.dumps(cfg,indent=2))
shutil.copyfile(src/'README.md',dst/'UPSTREAM_README.md')
model,tok=load(str(dst))
messages=[{'role':'user','content':'Return only JSON: {"ready":true}'}]
prompt=tok.apply_chat_template(messages,tokenize=False,add_generation_prompt=True,enable_thinking=False)
response=generate(model,tok,prompt=prompt,max_tokens=48,sampler=make_sampler(0))
files={p.name:{'bytes':p.stat().st_size,'sha256':hashlib.file_digest(p.open('rb'),'sha256').hexdigest()} for p in dst.iterdir() if p.is_file()}
report={'upstream_revision':'32f3e8ecf65426fc3306969496342d504bfa13f3','files':files,'total_bytes':sum(x['bytes'] for x in files.values()),'quantization':cfg['quantization'],'smoke_response':response,'mlx_peak_bytes':mx.get_peak_memory(),'text_only_tensor_count':len(weights)}
Path('.local/finetune/text_model_report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
assert report['total_bytes']<3_000_000_000
assert '<think>' not in response
