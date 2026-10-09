"""Same-set baselines before v2 training. Never access either final test."""
import argparse
import os
os.environ['HF_HUB_OFFLINE']='1'
os.environ['HF_HUB_DISABLE_TELEMETRY']='1'

import mlx.core as mx
from mlx_lm import load
from scripts.full_common import read_rows,write_json,sha256
from scripts.v2_common import ROOT,OUT,RUN,load_config,evaluate_rows


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--model',choices=('base','v1-comparable','v1-incumbent'),required=True)
    args=parser.parse_args()
    cfg=load_config()
    out=RUN/'baselines'/args.model
    if out.exists():
        raise FileExistsError('Baseline already measured or partially started')
    out.mkdir(parents=True)
    mx.set_memory_limit(14_000_000_000);mx.set_cache_limit(512_000_000)
    kwargs={} if args.model=='base' else {'adapter_path':str(ROOT/'package-full-v1/adapters')}
    model,tokenizer=load(cfg['model'],**kwargs)
    mode,prompt=('validated_retry','v1') if args.model=='v1-incumbent' else ('constrained','v2')
    for name,path in [('validation',OUT/'prepared/valid_records.jsonl'),
                      ('legacy',ROOT/'prepared/valid_records.jsonl')]:
        result=evaluate_rows(model,tokenizer,read_rows(path),out/name,mode,prompt)
        result.update(baseline=args.model,validation_sha256=sha256(path))
        write_json(out/f'{name}.json',result)


if __name__=='__main__':
    main()
