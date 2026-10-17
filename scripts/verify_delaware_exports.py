"""Offline format/tokenizer checks only; no model loading, inference or training.

Run qwen using .venv/bin/python and laya using .local/laya/.venv/bin/python.
The sealed real test is hashed for integrity, never parsed or evaluated.
"""
import argparse
import json
import os
from pathlib import Path

os.environ.update(HF_HUB_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1', TOKENIZERS_PARALLELISM='false')

from groundkeeper.laya_runtime import HEAD_MAX_LEN, MAX_LEN, QUESTIONS, training_row
from groundkeeper.policy import validate_answer, validate_input
from groundkeeper.policy_v2 import messages_v2
from scripts.prepare_delaware_labels import ROOT, read, sha


def verify(provider):
    prepared = ROOT / 'prepared'
    manifest = json.loads((prepared / 'manifest.json').read_text())
    assert all(sha(prepared / name) == digest for name, digest in manifest['sha256'].items())
    split_rows = read(prepared / 'split_manifest.jsonl')
    groups = {s: {r['merchant_family'] for r in split_rows if r['split'] == s} for s in ('train','valid','test')}
    assert not any(groups[a] & groups[b] for a,b in [('train','valid'),('train','test'),('valid','test')])
    maximum, counts, head_lengths = 0, {}, {}
    if provider == 'qwen':
        from mlx_lm.utils import load_tokenizer
        from mlx_lm.tuner.datasets import ChatDataset
        tokenizer = load_tokenizer(Path('.local/finetune/models/qwen35-text'))
    else:
        from transformers import AutoTokenizer
        from laya.common import build_head, build_sequence, encode_text, serialize_state
        from laya.train import items_from_rows, to_internal
        tokenizer = AutoTokenizer.from_pretrained('.local/laya/base-prepared/tokenizer', local_files_only=True)
        for field, question in QUESTIONS.items():
            head, markers, stats = build_head(tokenizer, to_internal(field, question), HEAD_MAX_LEN)
            full_head, _, _ = build_head(tokenizer, to_internal(field, question), 2048)
            assert head == full_head and stats['options_distinct'] == stats['options']
            assert len(markers) == len(question['criteria'])
            head_lengths[field] = len(head)
    for split in ('train','valid'):
        canonical = read(prepared / f'{split}.canonical.jsonl')
        exported = read(prepared / f'{split}.{provider}.jsonl')
        assert len(canonical) == len(exported) == manifest['split_counts'][split]
        for row in canonical:
            validate_input(row['input'])
            validate_answer(row['answer'])
            assert row['split'] == split and not row['human_confirmed']
        counts[split] = len(canonical)
        if provider == 'qwen':
            assert exported == [{'messages': messages_v2(r['input'], r['answer'])} for r in canonical]
            dataset = ChatDataset(exported, tokenizer, mask_prompt=True)
            for row in dataset._data:
                tokens, offset = dataset.process(row)
                prefix = tokenizer.apply_chat_template(row['messages'][:-1], tokenize=True,
                    add_generation_prompt=True, enable_thinking=False, return_dict=False)
                assert tokens[:offset] == prefix and 0 < offset < len(tokens) <= 512
                assert tokenizer.decode(tokens[offset:]).startswith('{"type":')
                maximum = max(maximum, len(tokens))
        else:
            assert exported == [training_row(r) for r in canonical]
            items, skipped = items_from_rows(tokenizer, exported, MAX_LEN, HEAD_MAX_LEN)
            assert not skipped and len(items) == 3 * len(canonical)
            for row in exported:
                state = encode_text(tokenizer, serialize_state(row['state']).replace(tokenizer.mask_token, ' '), add_special_tokens=False)['input_ids']
                for field, question in QUESTIONS.items():
                    assert head_lengths[field] + len(state) + 1 <= MAX_LEN
                    seq, markers = build_sequence(tokenizer, row['state'], to_internal(field, question), MAX_LEN, HEAD_MAX_LEN)
                    assert len(markers) == len(question['criteria'])
                    maximum = max(maximum, len(seq))
    report = {'provider': provider, 'passed': True, 'rows': counts,
              'maximum_sequence_tokens': maximum, 'sequence_limit': 512,
              'head_lengths': head_lengths, 'targets_match_canonical': True,
              'no_truncation': True, 'family_overlap_between_splits': 0,
              'sealed_test_parsed_or_evaluated': False, 'model_loaded': False,
              'inference_or_training_started': False, 'manifest_sha256': sha(prepared / 'manifest.json')}
    out = ROOT / 'verification'
    out.mkdir(exist_ok=True)
    (out / f'{provider}.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('provider', choices=['qwen','laya'])
    verify(parser.parse_args().provider)
