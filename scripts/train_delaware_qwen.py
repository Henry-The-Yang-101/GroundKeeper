"""One bounded, weights-only continuation from Qwen v2 on real weak labels.

Never opens either sealed test. Evaluation is serial with training. The parent
adapter is an immutable rollback; this script does not promote a deployment.
"""
import argparse
import importlib.metadata
import json
import math
import os
from pathlib import Path
import shutil
import time
from types import SimpleNamespace

os.environ.update(HF_HUB_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1', TOKENIZERS_PARALLELISM='false')

from scripts.common_io import read_rows, sha256, write_json

DATA = Path('.local/delaware-labeling-v1/prepared')
RUN = Path('.local/finetune/delaware-v1')
PUBLIC = Path('experiments/finetune/delaware-v1')
CONFIG = PUBLIC / 'training_config.json'
PARENT = Path('.local/finetune/v2/training/candidate-0/adapters')
BASE = Path('.local/finetune/models/qwen35-text')


def prepare():
    if RUN.exists() or CONFIG.exists():
        raise FileExistsError('Continuation already prepared; preserve it instead of restarting')
    manifest = json.loads((DATA / 'manifest.json').read_text())
    verification = json.loads(Path('.local/delaware-labeling-v1/verification/qwen.json').read_text())
    assert verification['passed'] and verification['manifest_sha256'] == sha256(DATA / 'manifest.json')
    paths = [DATA / f'{s}.{kind}.jsonl' for s in ('train', 'valid') for kind in ('canonical','qwen')]
    assert all(sha256(p) == manifest['sha256'][p.name] for p in paths)
    split = read_rows(DATA / 'split_manifest.jsonl')  # IDs/families only, no test examples.
    groups = {s: {r['merchant_family'] for r in split if r['split'] == s} for s in ('train','valid','test')}
    assert not any(groups[a] & groups[b] for a,b in [('train','valid'),('train','test'),('valid','test')])
    train, valid = [read_rows(DATA / f'{s}.canonical.jsonl') for s in ('train','valid')]
    assert len(train) == 5865 and len(valid) == 672
    assert all(r['split'] == 'train' for r in train) and all(r['split'] == 'valid' for r in valid)
    parent_config = json.loads((PARENT / 'adapter_config.json').read_text())
    source = PARENT / '0002080_adapters.safetensors'
    benchmark = json.loads(Path('.local/real-eval/delaware-100-20261017-v1/qwen-run.json').read_text())
    assert sha256(source) == benchmark['checkpoint_sha256']
    assert parent_config['num_layers'] == 4 and parent_config['lora_parameters']['rank'] == 8
    old_config = json.loads(Path('experiments/finetune/v2/training_config.json').read_text())
    old_valid = Path('.local/finetune/v2/prepared/valid_records.jsonl')
    assert sha256(old_valid) == old_config['data_hashes']['valid_records.jsonl']
    assert sha256(BASE / 'model.safetensors') == benchmark['base_weight_hashes']['model.safetensors']
    for name in ('groundkeeper/policy.py','groundkeeper/policy_v2.py'):
        assert sha256(name) == old_config['code_hashes'][name]
    RUN.mkdir(parents=True)
    (RUN / 'initial-adapter').mkdir()
    shutil.copy2(source, RUN / 'initial-adapter/adapters.safetensors')
    shutil.copy2(PARENT / 'adapter_config.json', RUN / 'initial-adapter/adapter_config.json')
    updates = math.ceil(len(train) / 8)
    iters = updates * 8
    checkpoints = [8 * math.ceil(updates * fraction / 3) for fraction in (1,2,3)]
    cfg = {
        'approval': 'User requested Qwen v2 continuation on new Delaware data; one check after 5 minutes, then no further progress monitoring.',
        'model': str(BASE), 'parent_checkpoint': str(source),
        'parent_sha256': sha256(source), 'resume_adapter_file': str(RUN / 'initial-adapter/adapters.safetensors'),
        'resume_optimizer_state': False, 'optimizer': 'adam', 'learning_rate': 2e-5,
        'train_n': len(train), 'valid_n': len(valid), 'test_n_reserved': manifest['split_counts']['test'],
        'old_validation_path': str(old_valid), 'old_validation_n': 279,
        'epochs': 1, 'iters': iters, 'optimizer_updates': updates,
        'repeated_train_rows_for_accumulation_alignment': iters - len(train),
        'batch_size': 1, 'grad_accumulation_steps': 8, 'max_seq_length': 512,
        'num_layers': parent_config['num_layers'], 'lora_parameters': parent_config['lora_parameters'],
        'mask_prompt': True, 'thinking': False, 'seed': 20261017,
        'checkpoint_steps': checkpoints, 'native_val_batches': 32,
        'selection': 'new validation supported-category macro-F1, exact decision agreement, fewer invalid outputs, earlier step; parent baseline eligible',
        'baseline_timing': 'full parent baseline at end, reloading frozen parent weights after saving final adapter',
        'old_validation_role': 'regression report only, never training',
        'test_accessed': False, 'diagnostic_100_used_for_training': False,
        'human_confirmed_labels': 0, 'real_data_labels': 'AI weak labels, not human gold',
        'data_manifest_sha256': sha256(DATA / 'manifest.json'),
        'data_hashes': {str(p): sha256(p) for p in paths + [old_valid]},
        'base_weight_sha256': benchmark['base_weight_hashes']['model.safetensors'],
        'code_hashes': {str(p): sha256(p) for p in [Path(__file__), *Path('groundkeeper').glob('*.py')]},
        'versions': {name: importlib.metadata.version(name) for name in ('mlx','mlx-lm','numpy')},
        'overall_seconds': 43200, 'evaluation_seconds_per_cohort': 1800,
        'mlx_memory_limit': 14_000_000_000, 'mlx_cache_limit': 512_000_000, 'rss_limit_gb': 18,
        'user_progress_checks': 1, 'progress_check_delay_seconds': 300,
        'automatic_restarts': False, 'automatic_production_promotion': False,
        'prepared_unix': time.time(),
    }
    write_json(CONFIG, cfg)
    print(json.dumps({k: cfg[k] for k in ('parent_checkpoint','parent_sha256','train_n','valid_n','learning_rate','iters','checkpoint_steps')}, indent=2))


def train():
    import mlx.core as mx
    import numpy as np
    from mlx.utils import tree_flatten
    from mlx_lm import load
    from mlx_lm.lora import CONFIG_DEFAULTS, train_model
    from mlx_lm.tuner.callbacks import TrainingCallback
    from mlx_lm.tuner.datasets import ChatDataset
    from groundkeeper.constraints import DecisionGrammar
    from groundkeeper.metrics import evaluate
    from groundkeeper.policy_v2 import messages_v2
    from groundkeeper.runtime_v2 import generate_decision

    cfg = json.loads(CONFIG.read_text())
    for path, digest in {**cfg['data_hashes'], **cfg['code_hashes']}.items():
        if sha256(path) != digest:
            raise ValueError(f'Frozen input/code changed: {path}')
    assert sha256(DATA / 'manifest.json') == cfg['data_manifest_sha256']
    assert sha256(cfg['parent_checkpoint']) == sha256(cfg['resume_adapter_file']) == cfg['parent_sha256']
    assert sha256(BASE / 'model.safetensors') == cfg['base_weight_sha256']
    with (RUN / 'started.json').open('x') as stream:
        json.dump({'pid': os.getpid(), 'started_unix': time.time(), 'config_sha256': sha256(CONFIG)}, stream)
    started = time.monotonic()
    reports = []
    def progress(phase, **extra):
        write_json(RUN / 'progress.json', {'pid': os.getpid(), 'phase': phase,
                   'elapsed_seconds': time.monotonic() - started, 'updated_unix': time.time(),
                   'total': cfg['iters'], **extra})
    def event(kind, **data):
        record = {'event': kind, 'elapsed_seconds': time.monotonic() - started, **data}
        with (RUN / 'events.jsonl').open('a') as stream:
            stream.write(json.dumps(record) + '\n')
        print(json.dumps(record), flush=True)

    progress('loading_checkpoint')
    mx.set_memory_limit(cfg['mlx_memory_limit'])
    mx.set_cache_limit(cfg['mlx_cache_limit'])
    model, tokenizer = load(cfg['model'])
    records = {s: read_rows(DATA / f'{s}.canonical.jsonl') for s in ('train','valid')}
    old_valid = read_rows(cfg['old_validation_path'])
    assert len(old_valid) == cfg['old_validation_n']
    datasets = [ChatDataset([{'messages': messages_v2(r['input'], r['answer'])} for r in records[s]],
                           tokenizer, mask_prompt=True) for s in ('train','valid')]
    for dataset in datasets:
        for item in dataset._data:
            tokens, offset = dataset.process(item)
            prefix = tokenizer.apply_chat_template(item['messages'][:-1], tokenize=True,
                      add_generation_prompt=True, enable_thinking=False, return_dict=False)
            assert tokens[:offset] == prefix and 0 < offset < len(tokens) <= cfg['max_seq_length']
    parent_weights = mx.load(cfg['resume_adapter_file'])
    def check_parent_weights():
        current = dict(tree_flatten(model.trainable_parameters()))
        assert set(current) == set(parent_weights), 'Parent adapter keys do not match adapted layers'
        assert all(bool(mx.array_equal(current[k], v).item()) for k,v in parent_weights.items()), 'Weights did not resume exactly'
        return len(current)

    def assess(rows, cohort, step):
        progress('validation', step=step, cohort=cohort)
        begin = time.monotonic()
        grammar = DecisionGrammar(tokenizer)
        predictions = []
        prefix = RUN / f'{cohort}-{step:07d}'
        if prefix.with_suffix('.json').exists():
            raise FileExistsError(prefix)
        with prefix.with_suffix('.jsonl').open('x') as stream:
            for index, row in enumerate(rows):
                if time.monotonic() - begin > cfg['evaluation_seconds_per_cohort']:
                    raise TimeoutError(f'{cohort} validation time bound')
                answer, detail = generate_decision(model, tokenizer, row['input'], grammar)
                prediction = {'id': row['id'], 'prediction': answer, **detail}
                predictions.append(prediction)
                stream.write(json.dumps(prediction) + '\n')
                if (index + 1) % 50 == 0:
                    progress('validation', step=step, cohort=cohort, evaluated=index+1, n=len(rows))
        result = {'step': step, 'cohort': cohort,
                  'metrics': evaluate([r['answer'] for r in rows], [p['prediction'] for p in predictions]),
                  'invalid_outputs': sum(not p['valid_schema'] for p in predictions),
                  'elapsed_seconds': time.monotonic() - begin,
                  'real_data': cohort == 'real-validation', 'labels': 'AI weak labels, not human gold',
                  'test_accessed': False}
        write_json(prefix.with_suffix('.json'), result)
        return result

    class Callback(TrainingCallback):
        def on_val_loss_report(self, data):
            if data['iteration'] == 0:
                count = check_parent_weights()
                write_json(RUN / 'resume_check.json', {'passed': True, 'trainable_tensors': count,
                    'parent_sha256': cfg['parent_sha256'], 'all_trainable_weights_exactly_match_parent': True,
                    'verified_before_first_gradient_step': True, 'optimizer_resumed': False})
                progress('training', step=0)
            event('sampled_validation_loss', **data)

        def on_train_loss_report(self, data):
            event('training', **data)
            step = data['iteration']
            progress('training', step=step, train_loss=data['train_loss'],
                     peak_memory_gb=data['peak_memory'], iterations_per_second=data['iterations_per_second'])
            if step not in cfg['checkpoint_steps']:
                return
            checkpoint = RUN / 'adapters' / f'{step:07d}_adapters.safetensors'
            mx.save_safetensors(str(checkpoint), dict(tree_flatten(model.trainable_parameters())))
            numpy_state = np.random.get_state()
            model.eval()
            try:
                result = assess(records['valid'], 'real-validation', step)
                regression = assess(old_valid, 'synthetic-validation', step)
            finally:
                model.train()
                np.random.set_state(numpy_state)
            result.update(checkpoint=str(checkpoint), checkpoint_sha256=sha256(checkpoint),
                          synthetic_validation_metrics=regression['metrics'])
            write_json(RUN / f'checkpoint-{step:07d}.json', result)
            reports.append(result)
            event('checkpoint_validation', step=step, metrics=result['metrics'],
                  synthetic_validation_metrics=regression['metrics'])
            progress('training', step=step)

    native = {**CONFIG_DEFAULTS, 'model': cfg['model'], 'adapter_path': str(RUN / 'adapters'),
              'data': str(DATA), 'fine_tune_type': 'lora', 'num_layers': cfg['num_layers'],
              'batch_size': cfg['batch_size'], 'grad_accumulation_steps': cfg['grad_accumulation_steps'],
              'iters': cfg['iters'], 'learning_rate': cfg['learning_rate'], 'optimizer': cfg['optimizer'],
              'optimizer_config': {}, 'max_seq_length': cfg['max_seq_length'], 'grad_checkpoint': True,
              'mask_prompt': True, 'steps_per_report': 8, 'steps_per_eval': cfg['iters'],
              'val_batches': cfg['native_val_batches'], 'save_every': cfg['iters'], 'seed': cfg['seed'],
              'lora_parameters': cfg['lora_parameters'], 'resume_adapter_file': cfg['resume_adapter_file'],
              'train': True, 'test': False, 'report_to': None, 'trust_remote_code': False}
    write_json(RUN / 'native_config.json', native)
    np.random.seed(cfg['seed'])
    progress('initial_validation_loss', step=0)
    try:
        train_model(SimpleNamespace(**native), model, datasets[0], datasets[1], Callback())
        assert sorted(r['step'] for r in reports) == cfg['checkpoint_steps']
        # All training outputs are saved. Reload parent into the same model for a
        # full baseline; this cannot overwrite saved continuation checkpoints.
        model.load_weights(cfg['resume_adapter_file'], strict=False)
        check_parent_weights()
        model.eval()
        baseline = assess(records['valid'], 'real-validation', 0)
        regression = assess(old_valid, 'synthetic-validation', 0)
        baseline.update(checkpoint=cfg['resume_adapter_file'], checkpoint_sha256=cfg['parent_sha256'],
                        synthetic_validation_metrics=regression['metrics'])
        write_json(RUN / 'parent_baseline.json', baseline)
        candidates = [baseline, *reports]
        chosen = max(candidates, key=lambda r: (r['metrics']['macro_f1_supported_categories'],
                     r['metrics']['joint_accuracy'], -r['invalid_outputs'], -r['step']))
        assert sha256(chosen['checkpoint']) == chosen['checkpoint_sha256']
        (RUN / 'selected-adapter').mkdir()
        shutil.copy2(chosen['checkpoint'], RUN / 'selected-adapter/adapters.safetensors')
        shutil.copy2(RUN / 'adapters/adapter_config.json', RUN / 'selected-adapter/adapter_config.json')
        write_json(RUN / 'selection.json', {'selected': chosen, 'parent_baseline': baseline,
                   'test_accessed': False, 'automatically_promoted': False, 'criterion': cfg['selection']})
        write_json(RUN / 'training_report.json', {'completed': True, 'microbatches': cfg['iters'],
                   'optimizer_updates': cfg['optimizer_updates'], 'train_n': cfg['train_n'],
                   'parent_sha256': cfg['parent_sha256'], 'elapsed_seconds': time.monotonic()-started,
                   'checkpoints': reports, 'selected_step': chosen['step'], 'test_accessed': False,
                   'human_confirmed_labels': 0, 'production_model_replaced': False})
        assert sha256(cfg['parent_checkpoint']) == cfg['parent_sha256']
        progress('complete', step=cfg['iters'], selected_step=chosen['step'])
    except BaseException as exc:
        progress('failed', error=f'{type(exc).__name__}: {exc}')
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['prepare','train'])
    args = parser.parse_args()
    prepare() if args.phase == 'prepare' else train()
