"""Compact, read-only status for the full-run follow-up checks."""
import json
import time

import psutil

from scripts.full_common import RUN


def main():
    result = {}
    for name in ['pipeline', 'progress', 'reported_progress']:
        path = RUN / f'{name}.json'
        if path.exists():
            result[name] = json.loads(path.read_text())
    pipeline = result.get('pipeline', {})
    if pipeline.get('pid'):
        try:
            process = psutil.Process(pipeline['pid'])
            result['pipeline_process_alive'] = (process.is_running()
                and process.status() != psutil.STATUS_ZOMBIE
                and abs(process.create_time() - pipeline['started_unix']) < 10)
        except psutil.Error:
            result['pipeline_process_alive'] = False
        result['elapsed_seconds'] = time.time() - pipeline['started_unix']
    result['checkpoints'] = []
    for path in sorted(RUN.glob('validation-*.json')):
        report = json.loads(path.read_text())
        # A report is initially published before its checkpoint metadata is added.
        if 'step' not in report:
            continue
        metrics = report['metrics']
        result['checkpoints'].append({
            'step': report['step'], 'n': metrics['n'],
            'category_accuracy': metrics['category_accuracy'],
            'macro_f1': metrics['macro_f1_supported_categories'],
            'joint_accuracy': metrics['joint_accuracy'],
            'invalid_outputs': report['invalid_outputs']})
    watchdog = RUN / 'runs/full-training.json'
    if watchdog.exists():
        result['watchdog'] = {k: v for k, v in json.loads(watchdog.read_text()).items()
                              if k != 'active_processes_before'}
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
