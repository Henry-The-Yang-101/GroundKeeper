"""Approved 632-microbatch run with validation at actual saved checkpoints."""
import argparse
import json
import os
import time
from pathlib import Path

os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'

import mlx.core as mx
import numpy as np
from mlx_lm import load
from mlx_lm.lora import CONFIG_DEFAULTS, train_model
from mlx_lm.tuner.callbacks import TrainingCallback
from mlx_lm.tuner.datasets import ChatDataset
from mlx.utils import tree_flatten
from types import SimpleNamespace

from groundkeeper.policy import messages
from scripts.full_common import ROOT, RUN, choose_checkpoint, evaluate_rows, read_rows, sha256, write_json


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    config_path = Path('experiments/finetune/proposed_full_config.json')
    cfg = json.loads(config_path.read_text())
    assert cfg['iters'] == 632 and cfg['grad_accumulation_steps'] == 8
    assert cfg['num_layers'] == 4 and cfg['lora_parameters']['rank'] == 8
    adapter_path = Path(cfg['adapter_path'])
    if adapter_path.exists():
        raise FileExistsError('Refusing to overwrite full-run adapters')
    train_rows = read_rows(ROOT / 'prepared/train_records.jsonl')
    valid_rows = read_rows(ROOT / 'prepared/valid_records.jsonl')
    assert len(train_rows) == 626 and len(valid_rows) == 116
    model, tokenizer = load(cfg['model'])
    mx.set_memory_limit(14_000_000_000)
    mx.set_cache_limit(512_000_000)
    datasets = []
    max_tokens = 0
    for rows in [train_rows, valid_rows]:
        data = ChatDataset([{'messages': messages(r['input'], r['answer'])}
                            for r in rows], tokenizer, mask_prompt=True)
        for row in data._data:
            tokens, offset = data.process(row)
            prefix = tokenizer.apply_chat_template(
                row['messages'][:-1], tokenize=True, add_generation_prompt=True,
                enable_thinking=False, return_dict=False)
            assert tokens[:offset] == prefix
            assert offset > 0 and offset < len(tokens) <= cfg['max_seq_length']
            assert tokenizer.decode(tokens[offset:]).startswith('{')
            max_tokens = max(max_tokens, len(tokens))
        datasets.append(data)
    if args.check_only:
        print(json.dumps({'check': 'passed', 'train': len(train_rows),
                          'valid': len(valid_rows), 'max_tokens': max_tokens,
                          'optimizer_updates': cfg['iters'] // 8}))
        return

    RUN.mkdir(parents=True, exist_ok=True)
    if (RUN / 'started.json').exists():
        raise FileExistsError('Full run already started; investigate instead of restarting')
    start = time.monotonic()
    baseline = json.loads((ROOT / 'probe-eval_report.json').read_text())
    best_accuracy = baseline['metrics']['category_accuracy']
    best_macro = baseline['metrics']['macro_f1_supported_categories']
    events, reports = [], []
    write_json(RUN / 'started.json', {
        'approval': 'User approved full training and improvement reports on 2026-10-09',
        'pid': os.getpid(), 'started_unix': time.time(), 'config': cfg,
        'code_sha256': sha256(__file__), 'config_sha256': sha256(config_path),
        'train_sha256': sha256(ROOT / 'prepared/train_records.jsonl'),
        'valid_sha256': sha256(ROOT / 'prepared/valid_records.jsonl'),
        'numpy_and_mlx_seed': cfg['seed'], 'initial_probe_accuracy': best_accuracy,
        'initial_probe_macro_f1': best_macro})

    class Callback(TrainingCallback):
        def record(self, kind, data):
            event = {'event': kind, **data, 'elapsed_seconds': time.monotonic() - start}
            events.append(event)
            with (RUN / 'events.jsonl').open('a') as stream:
                stream.write(json.dumps(event) + '\n')
            print(json.dumps(event), flush=True)

        def on_val_loss_report(self, data):
            self.record('sampled_validation_loss', data)

        def on_train_loss_report(self, data):
            nonlocal best_accuracy, best_macro
            self.record('train', data)
            step = data['iteration']
            write_json(RUN / 'progress.json', {'phase': 'training', 'step': step,
                       'total': cfg['iters'], 'elapsed_seconds': time.monotonic() - start})
            if step not in (128, 256, 384, 512, 632):
                return
            # Callback occurs after optimizer update and before native save. Save
            # these exact adapter values and score them without a second model.
            checkpoint = adapter_path / f'{step:07d}_adapters.safetensors'
            mx.save_safetensors(str(checkpoint), dict(tree_flatten(model.trainable_parameters())))
            digest = sha256(checkpoint)
            write_json(RUN / 'progress.json', {'phase': 'validation', 'step': step,
                       'total': cfg['iters'], 'elapsed_seconds': time.monotonic() - start})
            numpy_state = np.random.get_state()
            model.eval()
            try:
                result = evaluate_rows(model, tokenizer, valid_rows,
                                       RUN / f'validation-{step:07d}')
            finally:
                model.train()
                np.random.set_state(numpy_state)
            result.update(step=step, checkpoint=str(checkpoint), checkpoint_sha256=digest)
            write_json(RUN / f'validation-{step:07d}.json', result)
            reports.append(result)
            accuracy = result['metrics']['category_accuracy']
            macro = result['metrics']['macro_f1_supported_categories']
            self.record('checkpoint_validation', {
                'step': step, 'category_accuracy': accuracy, 'macro_f1': macro,
                'joint_accuracy': result['metrics']['joint_accuracy'],
                'invalid_outputs': result['invalid_outputs'],
                'new_accuracy_best': accuracy > best_accuracy,
                'new_macro_f1_best': macro > best_macro})
            best_accuracy, best_macro = max(best_accuracy, accuracy), max(best_macro, macro)

    np.random.seed(cfg['seed'])
    arguments = SimpleNamespace(**{**CONFIG_DEFAULTS, **cfg, 'resume_adapter_file': None,
                                  'train': True, 'test': False, 'report_to': None,
                                  'trust_remote_code': False})
    train_model(arguments, model, datasets[0], datasets[1], Callback())
    selected = choose_checkpoint(reports)
    assert sha256(selected['checkpoint']) == selected['checkpoint_sha256']
    write_json(RUN / 'selection.json', {
        'criterion': 'Highest supported-label macro-F1; ties: joint accuracy, fewer invalid outputs, earlier step',
        'selected': selected, 'test_accessed': False,
        'frozen_unix': time.time(), 'config_sha256': sha256(config_path)})
    write_json(RUN / 'training_report.json', {
        'config': cfg, 'microbatches': 632, 'optimizer_updates': 79,
        'elapsed_seconds_including_generation_validation': time.monotonic() - start,
        'mlx_peak_bytes': mx.get_peak_memory(), 'max_tokens': max_tokens,
        'train_n': len(train_rows), 'valid_n': len(valid_rows),
        'checkpoints': reports, 'events': events, 'selected_step': selected['step']})
    write_json(RUN / 'progress.json', {'phase': 'training_complete', 'step': 632,
               'selected_step': selected['step'], 'elapsed_seconds': time.monotonic() - start})


if __name__ == '__main__':
    main()
