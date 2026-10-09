"""Package frozen v2 choice, reload copied runtime, then score new test once."""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

os.environ['HF_HUB_OFFLINE']='1'
os.environ['HF_HUB_DISABLE_TELEMETRY']='1'

from scripts.full_common import read_rows,sha256,write_json
from scripts.v2_common import ROOT,OUT,RUN,PUBLIC,CONFIG,load_config,evaluate_rows


def main():
    cfg=load_config()
    selection=json.loads((RUN/'selection.json').read_text())
    chosen=selection['selected']
    if selection['test_accessed'] or sha256(chosen['checkpoint'])!=chosen['checkpoint_sha256']:
        raise ValueError('Selection integrity failure')
    package=ROOT/'package-v2'
    if package.exists():
        raise FileExistsError('Do not overwrite a model package')
    shutil.copytree(ROOT/'models/qwen35-text',package/'model')
    (package/'adapters').mkdir()
    shutil.copyfile(chosen['checkpoint'],package/'adapters/adapters.safetensors')
    shutil.copyfile(Path(chosen['checkpoint']).parent/'adapter_config.json',package/'adapters/adapter_config.json')
    (package/'groundkeeper').mkdir()
    for path in Path('groundkeeper').glob('*.py'):
        shutil.copyfile(path,package/'groundkeeper'/path.name)
    shutil.copyfile('experiments/finetune/LABELING_POLICY.md',package/'LABELING_POLICY.md')
    shutil.copyfile(PUBLIC/'POLICY_ADDITIONS.md',package/'POLICY_ADDITIONS.md')
    shutil.copyfile('uv.lock',package/'uv.lock')
    shutil.copyfile('pyproject.toml',package/'pyproject.toml')
    write_json(package/'runtime.json',{'class':'groundkeeper.runtime_v2.StructuredCategorizer',
        'mode':'constrained','prompt_version':'v2','thinking':False,
        'model':'model','adapters':'adapters','application_review_required':True})
    (package/'EXPERIMENTAL.txt').write_text('AI-reviewed synthetic training/evaluation only. '
        'No real calibration. All model suggestions require application review. '
        'The base and v1 package remain available for rollback.\n')
    valid=read_rows(OUT/'prepared/valid_records.jsonl')
    old_predictions=read_rows(Path(chosen['checkpoint']).parent.parent/f"validation-{chosen['step']:07d}.jsonl")
    check_inputs=RUN/'reload-inputs.json'
    write_json(check_inputs,[r['input'] for r in valid[:3]])
    # Fresh interpreter imports the COPIED package runtime and loads COPIED
    # weights. Parent has no loaded model, so the GPU jobs remain serial.
    code='''import json,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import groundkeeper.runtime_v2 as runtime
from groundkeeper.policy import validate_answer
package=Path(sys.argv[1])
assert Path(runtime.__file__).resolve().is_relative_to(package)
runner=runtime.StructuredCategorizer(package/'model',package/'adapters')
inputs=json.loads(Path(sys.argv[2]).read_text())
predictions=[runtime.generate_decision(runner.model,runner.tokenizer,row,runner.grammar)[0] for row in inputs]
smoke_inputs=[{'description':d,'direction':direction,'currency':c} for d,direction,c in [
('TIM HORTONS','debit','CAD'),('STARBUCKS','debit','USD'),('AMAZON MKTP','debit','USD'),
('PAYROLL SALARY','credit','CAD'),('INTERAC TO ALEX','debit','CAD')]]
smoke=[runner.suggest(row) for row in smoke_inputs]
assert all(validate_answer(row) and row['review'] is True for row in smoke)
Path(sys.argv[3]).write_text(json.dumps({'predictions':predictions,'smoke':smoke,'runtime_file':str(Path(runtime.__file__).resolve())},indent=2))
'''
    subprocess.run([sys.executable,'-c',code,str(package.resolve()),str(check_inputs.resolve()),
                    str((RUN/'reload-check.json').resolve())],check=True,timeout=300)
    reload_result=json.loads((RUN/'reload-check.json').read_text())
    if reload_result['predictions']!=[r['prediction'] for r in old_predictions[:3]]:
        raise ValueError('Packaged checkpoint/runtime predictions differ')
    files={str(path.relative_to(package)):{'bytes':path.stat().st_size,'sha256':sha256(path)}
           for path in package.rglob('*') if path.is_file() and '__pycache__' not in path.parts}
    # Python cache is incidental and excluded from the distributable bundle.
    for path in package.rglob('__pycache__'):
        shutil.rmtree(path)
    write_json(package/'manifest.json',{'files':files,'selected_candidate':chosen['candidate'],
        'selected_step':chosen['step'],'adapter_sha256':chosen['checkpoint_sha256'],
        'selection_sha256':sha256(RUN/'selection.json'),
        'model_revision':'32f3e8ecf65426fc3306969496342d504bfa13f3',
        'packaged_runtime_reload_verified':True,'application_review_required':True})
    total=sum(path.stat().st_size for path in package.rglob('*') if path.is_file())
    if total>=3_000_000_000:
        raise ValueError('Package exceeds size constraint')
    for name,meta in files.items():
        if sha256(package/name)!=meta['sha256']:
            raise ValueError('Package file changed during verification')
    write_json(RUN/'package_report.json',{'package':str(package),'total_bytes':total,
        'under_limit':True,'adapter_sha256':chosen['checkpoint_sha256'],
        'three_reloaded_validation_predictions_match':True,'packaged_runtime_import_verified':True,
        'all_smoke_review_required':True,'smoke_count':5,
        'rollback_base':str(ROOT/'models/qwen35-text'),'rollback_v1':str(ROOT/'package-full-v1')})

    test_path=OUT/'prepared/test_records.jsonl'
    if sha256(test_path)!=cfg['data_hashes']['test_records.jsonl']:
        raise ValueError('Sealed test changed')
    with (RUN/'final_test_started.json').open('x') as stream:
        json.dump({'selection_sha256':sha256(RUN/'selection.json'),
                   'started_unix':time.time(),'final_test_passes':1},stream)
    from groundkeeper.runtime_v2 import StructuredCategorizer
    runtime=StructuredCategorizer(package/'model',package/'adapters')
    test=evaluate_rows(runtime.model,runtime.tokenizer,read_rows(test_path),RUN/'final-test')
    test.update(final_test_passes=1,selected_candidate=chosen['candidate'],selected_step=chosen['step'],
                selection_sha256=sha256(RUN/'selection.json'),test_sha256=sha256(test_path))
    write_json(RUN/'final-test.json',test)
    dest=PUBLIC/'results'
    dest.mkdir(exist_ok=True)
    for path in RUN.rglob('*.json'):
        if path.name in ('reload-inputs.json',):
            continue
        target=dest/path.relative_to(RUN)
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(path,target)
    shutil.copyfile(package/'manifest.json',dest/'package_manifest.json')
    lines=['# V2 coverage-repair results','',
        'Synthetic text with AI-reviewed labels. These scores do not establish real-world accuracy.',
        'Selection used new validation only; legacy validation is a separate regression measure.', '',
        '| Model | New validation category accuracy | Macro-F1 | Exact three-field accuracy | Invalid |',
        '|---|---:|---:|---:|---:|']
    compare=[(name,json.loads((RUN/f'baselines/{name}/validation.json').read_text()))
             for name in ('base','v1-comparable','v1-incumbent')]
    compare.append((f"v2 candidate {chosen['candidate']} step {chosen['step']}",chosen))
    for name,report in compare:
        m=report['metrics']
        lines.append(f"| {name} | {m['category_accuracy']:.1%} | {m['macro_f1_supported_categories']:.3f} | {m['joint_accuracy']:.1%} | {report['invalid_outputs']}/{m['n']} |")
    m=test['metrics']
    lines += ['',f"New final synthetic test, evaluated exactly once: n={m['n']}, category accuracy {m['category_accuracy']:.1%}, supported-category macro-F1 {m['macro_f1_supported_categories']:.3f}, exact decision accuracy {m['joint_accuracy']:.1%}.",
        '',f'Package: {total:,} bytes. Copied runtime and adapters were reloaded in a fresh process and matched the selected checkpoint.',
        '', 'The JSON type/category/review contract is preserved. Every model suggestion requires review. No numeric confidence or real-data calibration is claimed.',
        '', 'Limitations: authored US/Canadian wording and synthetic public US data; AI label errors may remain; small held-out groups and template effects; bank transaction distribution and regional generalization need real validation.', '']
    (dest/'RESULTS.md').write_text('\n'.join(lines))
    write_json(RUN/'progress.json',{'phase':'complete','candidate':chosen['candidate'],
        'step':chosen['step'],'package_bytes':total,'final_test_passes':1})


if __name__=='__main__':
    main()
