"""Run the approved training and finalization serially under one watchdog."""
import os
import subprocess
import sys
import time

from scripts.full_common import RUN
from scripts.common_io import write_json


def main():
    RUN.mkdir(parents=True, exist_ok=True)
    status = {'pid': os.getpid(), 'started_unix': time.time(), 'status': 'running'}
    write_json(RUN / 'pipeline.json', status)
    try:
        for module, timeout in [('scripts.run_full_training', 3000),
                                ('scripts.finalize_full_training', 600)]:
            status['phase'] = module
            write_json(RUN / 'pipeline.json', status)
            subprocess.run([sys.executable, '-m', module], check=True, timeout=timeout)
        status.update(status='completed', finished_unix=time.time())
    except BaseException as exc:
        status.update(status='failed', error=str(exc), finished_unix=time.time())
        raise
    finally:
        write_json(RUN / 'pipeline.json', status)


if __name__ == '__main__':
    main()
