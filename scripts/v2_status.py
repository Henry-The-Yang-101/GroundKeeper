"""Compact read-only preparation/training status; no model or test loading."""
import json
from pathlib import Path
import psutil


def main():
    root=Path('.local/finetune/v2')
    paths=['status.json','labeling_status.json','reported_progress.json',
           'training/pipeline.json','training/selection.json','training/progress.json',
           'training-runs/v2-full.json']
    result={name:json.loads((root/name).read_text()) for name in paths if (root/name).exists()}
    result['candidate_progress']={str(p.parent.name):json.loads(p.read_text())
                                 for p in (root/'training').glob('candidate-*/progress.json')}
    result['completed_validation']=[str(p) for p in (root/'training').glob('candidate-*/validation-*.json')]
    result['model_processes']=[{'pid':p.pid,'name':p.info['name'],'rss':p.info['memory_info'].rss}
        for p in psutil.process_iter(['name','memory_info'])
        if any(term in (p.info['name'] or '').lower() for term in ('python','mlx','ollama'))]
    print(json.dumps(result,indent=2))


if __name__=='__main__':
    main()
