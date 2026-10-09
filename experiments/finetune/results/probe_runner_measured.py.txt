"""Bounded native MLX experiment. Final test labels are never opened here."""
import argparse,json,os,time,hashlib
from pathlib import Path
os.environ['HF_HUB_OFFLINE']='1';os.environ['HF_HUB_DISABLE_TELEMETRY']='1'
import mlx.core as mx
from mlx_lm import load,generate
from mlx_lm.sample_utils import make_sampler
from mlx_lm.lora import train_model,CONFIG_DEFAULTS
from mlx_lm.tuner.datasets import ChatDataset
from mlx_lm.tuner.callbacks import TrainingCallback
from mlx.utils import tree_flatten
from types import SimpleNamespace
from groundkeeper.policy import messages,validate_answer,safe_prediction
from groundkeeper.metrics import evaluate
from groundkeeper.runtime import generate_answer

root=Path('.local/finetune');model_path=root/'models/qwen35-text'
p=argparse.ArgumentParser();p.add_argument('mode',choices=['check','baseline','probe','probe-eval']);a=p.parse_args()
train_rows=[json.loads(s) for s in (root/'prepared/train_records.jsonl').read_text().splitlines()]
valid_rows=[json.loads(s) for s in (root/'prepared/valid_records.jsonl').read_text().splitlines()]
# Never open the final test path while selecting prompts/settings/checkpoints.
adapter=str(root/'adapters/probe') if a.mode=='probe-eval' else None
model,tok=load(str(model_path),adapter_path=adapter)
mx.set_memory_limit(14_000_000_000);mx.set_cache_limit(512_000_000)
train_data=[{'messages':messages(r['input'],r['answer'])} for r in train_rows]
valid_data=[{'messages':messages(r['input'],r['answer'])} for r in valid_rows]
train=ChatDataset(train_data,tok,mask_prompt=True);valid=ChatDataset(valid_data,tok,mask_prompt=True)
lengths=[];answers=[]
for data in (train,valid):
 for row in data._data:
  tokens,offset=data.process(row)
  prefix=tok.apply_chat_template(row['messages'][:-1],tokenize=True,add_generation_prompt=True,enable_thinking=False,return_dict=False)
  assert tokens[:offset]==prefix,'Training/inference prompt tokens differ'
  assert len(tokens)<=512,('Would truncate',len(tokens))
  assert len(tokens)>offset and offset>0
  # Loss starts at exactly first answer token, not the empty thinking prefix.
  assert tok.decode(tokens[offset:]).startswith('{')
  lengths.append(len(tokens));answers.append(len(tokens)-offset)
report={'mode':a.mode,'train_n':len(train_rows),'valid_n':len(valid_rows),'max_tokens':max(lengths),'min_answer_tokens':min(answers),'prompt_mask_verified':True,'thinking_disabled':True}
if a.mode=='check':
 from mlx_lm.tuner.utils import linear_to_lora_layers
 model.freeze();linear_to_lora_layers(model,4,{'rank':8,'scale':2.0,'dropout':0.0,'keys':['self_attn.q_proj','self_attn.v_proj','linear_attn.in_proj_qkv','linear_attn.in_proj_z']})
 params=dict(tree_flatten(model.trainable_parameters()));report['adapter_parameters']={k:list(v.shape) for k,v in params.items()};report['trainable_parameter_count']=sum(v.size for v in params.values())
 assert params and all('lora_' in k for k in params)
 report['adapted_layer_indices']=sorted({int(k.split('.layers.')[1].split('.')[0]) for k in params})
 assert report['adapted_layer_indices']==[28,29,30,31]
 (root/'compatibility_check.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
elif a.mode in ('baseline','probe-eval'):
 outputs=[];raw_outputs=[];times=[];invalid=0;repaired=0
 for i,r in enumerate(valid_rows):
  answer,details=generate_answer(model,tok,r['input']);text=details['raw'];times.append(details['latency_seconds'])
  if not details['valid_schema']:invalid+=1
  repaired+=int(details['removed_json_fence'])
  outputs.append(answer);raw_outputs.append({'id':r['id'],'prediction':answer,'raw':text})
  if (i+1)%10==0:print('evaluated',i+1,'/',len(valid_rows),flush=True)
 result=evaluate([r['answer'] for r in valid_rows],outputs)
 for source in sorted({r['source'] for r in valid_rows}):
  indices=[i for i,r in enumerate(valid_rows) if r['source']==source]
  result.setdefault('by_source',{})[source]=evaluate([valid_rows[i]['answer'] for i in indices],[outputs[i] for i in indices])
 report.update(metrics=result,invalid_outputs=invalid,format_repaired_outputs=repaired,mean_latency_seconds=sum(times)/len(times),total_generation_seconds=sum(times),mlx_peak_bytes=mx.get_peak_memory(),all_validation_merchants='unseen_in_training',matching_unresolved_count=len(valid_rows),real_user_confirmed_aliases=0)
 (root/f'{a.mode}_predictions.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in raw_outputs));(root/f'{a.mode}_report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
else:
 events=[]
 class Callback(TrainingCallback):
  def record(self,kind,data):
   event={'event':kind,**data,'wall_seconds':time.perf_counter()-start,'mlx_peak_bytes':mx.get_peak_memory()};events.append(event)
   with (root/'probe_events.jsonl').open('a') as f:f.write(json.dumps(event)+'\n')
   print(json.dumps(event),flush=True)
  def on_train_loss_report(self,d):self.record('train',d)
  def on_val_loss_report(self,d):self.record('validation',d)
 cfg=json.loads(Path('experiments/finetune/probe_config.json').read_text())
 assert cfg['iters']==128 and cfg['grad_accumulation_steps']==8
 assert not Path(cfg['adapter_path']).exists(),'Do not overwrite a probe'
 args=SimpleNamespace(**{**CONFIG_DEFAULTS,**cfg,'resume_adapter_file':None,'train':True,'test':False,'report_to':None,'trust_remote_code':False})
 start=time.perf_counter();train_model(args,model,train,valid,Callback());elapsed=time.perf_counter()-start
 report.update(config=cfg,elapsed_seconds=elapsed,mlx_peak_bytes=mx.get_peak_memory(),microbatches=128,optimizer_updates=16,events=events)
 report['seconds_per_microbatch_including_validation']=elapsed/128
 report['estimated_one_epoch_seconds_including_validation']=elapsed/128*len(train_rows)
 report['one_epoch_microbatches']=len(train_rows);report['one_epoch_optimizer_updates']=(len(train_rows)+7)//8
 (root/'probe_report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
