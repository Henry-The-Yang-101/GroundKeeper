"""Package the frozen validation choice and evaluate the final category test once."""
import json
import shutil
import time
from pathlib import Path

from groundkeeper.runtime import LocalCategorizer
from scripts.full_common import ROOT, RUN, evaluate_rows, read_rows, sha256, write_json


def main():
    selection_path = RUN / 'selection.json'
    selection = json.loads(selection_path.read_text())
    chosen = selection['selected']
    assert selection['test_accessed'] is False
    assert sha256(chosen['checkpoint']) == chosen['checkpoint_sha256']
    package = ROOT / 'package-full-v1'
    if package.exists():
        raise FileExistsError('Refusing to replace an existing package')
    (package / 'model').mkdir(parents=True)
    (package / 'adapters').mkdir()
    for source in (ROOT / 'models/qwen35-text').iterdir():
        if source.is_file():
            shutil.copyfile(source, package / 'model' / source.name)
    shutil.copyfile(chosen['checkpoint'], package / 'adapters/adapters.safetensors')
    shutil.copyfile(ROOT / 'adapters/full-v1/adapter_config.json',
                    package / 'adapters/adapter_config.json')
    shutil.copyfile('experiments/finetune/LABELING_POLICY.md', package / 'LABELING_POLICY.md')
    (package / 'EXPERIMENTAL.txt').write_text(
        'Public/synthetic-data experiment. No real calibration. All model suggestions '
        'require review. Original base and probe remain available for rollback.\n')
    runtime = LocalCategorizer(package / 'model', package / 'adapters')
    # Confirm saved adapters reload to the same decisions on three validation
    # inputs before the final test is accessed. This is not checkpoint selection.
    valid = read_rows(ROOT / 'prepared/valid_records.jsonl')
    previous = read_rows(RUN / f"validation-{chosen['step']:07d}.jsonl")
    smoke_report = evaluate_rows(runtime.model, runtime.tokenizer, valid[:3], RUN / 'reload-check')
    reloaded = read_rows(RUN / 'reload-check.jsonl')
    assert [r['prediction'] for r in reloaded] == [r['prediction'] for r in previous[:3]]
    smoke_inputs = [
        {'description': description, 'direction': direction, 'currency': currency}
        for description, direction, currency in [
            ('TIM HORTONS', 'debit', 'CAD'), ('STARBUCKS', 'debit', 'USD'),
            ('AMAZON MKTP', 'debit', 'USD'), ('PAYROLL SALARY', 'credit', 'CAD'),
            ('INTERAC TO ALEX', 'debit', 'CAD')]]
    smoke = [runtime.suggest(row) for row in smoke_inputs]
    assert all(r['review'] is True for r in smoke)
    files = {str(p.relative_to(package)): {'bytes': p.stat().st_size, 'sha256': sha256(p)}
             for p in package.rglob('*') if p.is_file()}
    write_json(package / 'manifest.json', {
        'files': files, 'selected_step': chosen['step'],
        'selection_sha256': sha256(selection_path), 'runtime': 'groundkeeper.runtime.LocalCategorizer',
        'model_revision': '32f3e8ecf65426fc3306969496342d504bfa13f3',
        'thinking': False, 'status': 'synthetic_experiment_review_required',
        'smoke': smoke, 'reloaded_validation_predictions_match': True})
    total = sum(p.stat().st_size for p in package.rglob('*') if p.is_file())
    assert total < 3_000_000_000
    write_json(RUN / 'package_report.json', {
        'package': str(package), 'total_bytes': total, 'under_limit': True,
        'selected_step': chosen['step'], 'smoke_count': len(smoke),
        'all_smoke_schema_valid': True, 'all_smoke_review_required': True,
        'three_reloaded_validation_predictions_match': True,
        'rollback_base': str(ROOT / 'models/qwen35-text'),
        'rollback_probe': str(ROOT / 'package-probe')})

    dataset_report = json.loads(Path('experiments/finetune/dataset_report.json').read_text())
    test_path = ROOT / 'sealed_test_records.jsonl'
    assert sha256(test_path) == dataset_report['sealed_test_sha256']
    with (RUN / 'final_test_started.json').open('x') as stream:
        json.dump({'selection_sha256': sha256(selection_path), 'started_unix': time.time()}, stream)
    rows = read_rows(test_path)
    test_report = evaluate_rows(runtime.model, runtime.tokenizer, rows, RUN / 'final-test')
    test_report.update(selected_step=chosen['step'], n=len(rows),
                       selection_sha256=sha256(selection_path), real_data=False,
                       unknown_merchants=True, final_test_passes=1)
    write_json(RUN / 'final-test.json', test_report)

    dest = Path('experiments/finetune/full-results')
    dest.mkdir(exist_ok=True)
    for source in sorted(RUN.glob('*.json')):
        shutil.copyfile(source, dest / source.name)
    shutil.copyfile(package / 'manifest.json', dest / 'package_manifest.json')
    training = json.loads((RUN / 'training_report.json').read_text())
    lines = ['# Full JSON-output training results', '',
             'Completed the approved 632-microbatch / 79-update run on 626 AI-reviewed synthetic training rows.',
             'Selection uses only 116 validation examples. No real transaction calibration is available.', '',
             '| Checkpoint | Category accuracy | Macro-F1 | Exact JSON decision accuracy | Invalid outputs |',
             '|---|---:|---:|---:|---:|']
    for row in training['checkpoints']:
        metrics = row['metrics']
        lines.append(f"| {row['step']} | {metrics['category_accuracy']:.1%} | "
                     f"{metrics['macro_f1_supported_categories']:.3f} | "
                     f"{metrics['joint_accuracy']:.1%} | {row['invalid_outputs']}/116 |")
    metrics = test_report['metrics']
    lines += ['', f"Selected checkpoint: **{chosen['step']}**, using the predeclared macro-F1/tie-break rule.", '',
              f"The final synthetic test was evaluated once after freezing selection: n={len(rows)}, "
              f"category accuracy {metrics['category_accuracy']:.1%}, "
              f"supported-label macro-F1 {metrics['macro_f1_supported_categories']:.3f}, "
              f"exact three-field accuracy {metrics['joint_accuracy']:.1%}. "
              'This is not a second validation score or real-world accuracy estimate.', '',
              f"Training plus checkpoint validation: {training['elapsed_seconds_including_generation_validation']/60:.1f} minutes. "
              f"Peak MLX allocation: {training['mlx_peak_bytes']:,} bytes. "
              f"Packaged model: {total:,} bytes, below 3 GB decimal.", '',
              'The JSON contract remains type/category/review, with no numeric confidence. '
              'All model suggestions still require application review. Acceptance coverage is zero; '
              'accepted-error rate is undefined. Per-source and per-category metrics are in the JSON reports.', '',
              'Limitations: AI labels, synthetic data, sparse classes, small Canadian subset, no real calibration, '
              'no future-known-merchant test, no production deployment. Base and probe remain available for rollback.', '']
    (dest / 'RESULTS.md').write_text('\n'.join(lines))
    write_json(RUN / 'progress.json', {'phase': 'complete', 'step': 632,
               'selected_step': chosen['step'], 'test_scored_once': True, 'package_bytes': total})


if __name__ == '__main__':
    main()
