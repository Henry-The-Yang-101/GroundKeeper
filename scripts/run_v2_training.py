"""Train one frozen v2 candidate; serial validation at real saved checkpoints."""
import argparse
import json
import os
import time
from types import SimpleNamespace

os.environ['HF_HUB_OFFLINE']='1'
os.environ['HF_HUB_DISABLE_TELEMETRY']='1'

import mlx.core as mx
import numpy as np
from mlx.utils import tree_flatten
from mlx_lm import load
from mlx_lm.lora import CONFIG_DEFAULTS,train_model
from mlx_lm.tuner.callbacks import TrainingCallback
from mlx_lm.tuner.datasets import ChatDataset

from groundkeeper.policy_v2 import messages_v2
from scripts.common_io import read_rows, sha256, write_json
from scripts.v2_common import ROOT,OUT,RUN,CONFIG,load_config,evaluate_rows


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--candidate',type=int,choices=(0,1),required=True)
    args=parser.parse_args()
    cfg=load_config()
    out=RUN/f'candidate-{args.candidate}'
    if out.exists():
        raise FileExistsError('Candidate already started; investigate instead of restarting')
    out.mkdir(parents=True)
    adapter_path=out/'adapters'
    train=read_rows(OUT/'prepared/train_records.jsonl')
    valid=read_rows(OUT/'prepared/valid_records.jsonl')
    legacy=read_rows(ROOT/'prepared/valid_records.jsonl')
    mx.set_memory_limit(14_000_000_000)
    mx.set_cache_limit(512_000_000)
    model,tokenizer=load(cfg['model'])
    datasets=[ChatDataset([{'messages':messages_v2(r['input'],r['answer'])} for r in rows],
                         tokenizer,mask_prompt=True) for rows in (train,valid)]
    for dataset in datasets:
        for item in dataset._data:
            tokens,offset=dataset.process(item)
            if not 0<offset<len(tokens)<=cfg['max_seq_length']:
                raise ValueError('Training input changed after preflight')
    start=time.monotonic()
    events=[];reports=[]
    native={**CONFIG_DEFAULTS,'model':cfg['model'],'adapter_path':str(adapter_path),
        'fine_tune_type':'lora','num_layers':cfg['num_layers'],'batch_size':1,
        'grad_accumulation_steps':8,'iters':cfg['iters'],
        'learning_rate':cfg['learning_rates'][args.candidate],
        'optimizer':'adam','optimizer_config':{},'max_seq_length':cfg['max_seq_length'],
        'grad_checkpoint':True,'mask_prompt':True,'steps_per_report':8,
        'steps_per_eval':cfg['iters'],'val_batches':8,'save_every':cfg['iters'],
        'seed':cfg['seed'],'lora_parameters':cfg['lora_parameters'],
        'resume_adapter_file':None,'train':True,'test':False,'report_to':None,'trust_remote_code':False}
    write_json(out/'started.json',{'pid':os.getpid(),'started_unix':time.time(),
        'config_sha256':sha256(CONFIG),'candidate':args.candidate,'native_config':native})

    class Callback(TrainingCallback):
        def record(self,kind,data):
            event={'event':kind,**data,'elapsed_seconds':time.monotonic()-start}
            events.append(event)
            with (out/'events.jsonl').open('a') as stream:
                stream.write(json.dumps(event)+'\n')
            print(json.dumps(event),flush=True)

        def on_val_loss_report(self,data):
            self.record('sampled_validation_loss',data)

        def on_train_loss_report(self,data):
            self.record('training',data)
            step=data['iteration']
            write_json(out/'progress.json',{'phase':'training','step':step,'total':cfg['iters'],
                'elapsed_seconds':time.monotonic()-start})
            if step not in cfg['checkpoint_steps']:
                return
            checkpoint=adapter_path/f'{step:07d}_adapters.safetensors'
            mx.save_safetensors(str(checkpoint),dict(tree_flatten(model.trainable_parameters())))
            digest=sha256(checkpoint)
            write_json(out/'progress.json',{'phase':'validation','step':step,'total':cfg['iters']})
            numpy_state=np.random.get_state()
            model.eval()
            try:
                result=evaluate_rows(model,tokenizer,valid,out/f'validation-{step:07d}')
                legacy_result=evaluate_rows(model,tokenizer,legacy,out/f'legacy-{step:07d}')
            finally:
                model.train()
                np.random.set_state(numpy_state)
            result.update(candidate=args.candidate,step=step,checkpoint=str(checkpoint),
                checkpoint_sha256=digest,validation_sha256=cfg['data_hashes']['valid_records.jsonl'],
                legacy_metrics=legacy_result['metrics'])
            write_json(out/f'validation-{step:07d}.json',result)
            reports.append(result)
            self.record('checkpoint_validation',{'candidate':args.candidate,'step':step,
                'category_accuracy':result['metrics']['category_accuracy'],
                'macro_f1_supported_categories':result['metrics']['macro_f1_supported_categories'],
                'joint_accuracy':result['metrics']['joint_accuracy'],'invalid_outputs':result['invalid_outputs']})

    np.random.seed(cfg['seed'])
    train_model(SimpleNamespace(**native),model,datasets[0],datasets[1],Callback())
    if sorted(r['step'] for r in reports)!=cfg['checkpoint_steps']:
        raise ValueError('Missing saved-checkpoint evaluations')
    write_json(out/'training_report.json',{'candidate':args.candidate,
        'learning_rate':cfg['learning_rates'][args.candidate],'microbatches':cfg['iters'],
        'optimizer_updates':cfg['iters']//8,'elapsed_seconds':time.monotonic()-start,
        'mlx_peak_bytes':mx.get_peak_memory(),'checkpoints':reports,'events':events})
    write_json(out/'progress.json',{'phase':'complete','step':cfg['iters'],
                                  'elapsed_seconds':time.monotonic()-start})


if __name__=='__main__':
    main()
