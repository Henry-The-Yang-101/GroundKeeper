"""One serial, bounded v2 experiment. Refuse duplicate/restarted pipelines."""
import json
import os
import subprocess
import sys
import time

from scripts.common_io import sha256, write_json
from scripts.v2_common import RUN,CONFIG,load_config,choose


def main():
    cfg=load_config()
    RUN.mkdir(parents=True,exist_ok=True)
    with (RUN/'started.json').open('x') as stream:
        json.dump({'pid':os.getpid(),'started_unix':time.time(),'config_sha256':sha256(CONFIG)},stream)
    status={'pid':os.getpid(),'started_unix':time.time(),'status':'running'}
    write_json(RUN/'pipeline.json',status)
    jobs=[(['scripts.evaluate_v2_baselines','--model',name],2400)
          for name in ('base','v1-comparable','v1-incumbent')]
    jobs += [(['scripts.run_v2_training','--candidate',str(i)],cfg['candidate_seconds']) for i in range(2)]
    try:
        for arguments,timeout in jobs:
            status['phase']=' '.join(arguments)
            write_json(RUN/'pipeline.json',status)
            subprocess.run([sys.executable,'-m',*arguments],check=True,timeout=timeout)
        reports=[json.loads(path.read_text()) for path in RUN.glob('candidate-*/validation-*.json')]
        selected=choose(reports,cfg['checkpoint_steps'])
        if sha256(selected['checkpoint'])!=selected['checkpoint_sha256']:
            raise ValueError('Selected adapter changed')
        write_json(RUN/'selection.json',{'selected':selected,'test_accessed':False,
            'frozen_unix':time.time(),'config_sha256':sha256(CONFIG),
            'criterion':'new validation supported-category macro-F1, joint accuracy, fewer invalids, earlier step, candidate index'})
        status['phase']='scripts.finalize_v2'
        write_json(RUN/'pipeline.json',status)
        subprocess.run([sys.executable,'-m','scripts.finalize_v2'],check=True,timeout=2400)
        status.update(status='completed',finished_unix=time.time())
    except BaseException as exc:
        status.update(status='failed',error=str(exc),finished_unix=time.time())
        raise
    finally:
        write_json(RUN/'pipeline.json',status)


if __name__=='__main__':
    main()
