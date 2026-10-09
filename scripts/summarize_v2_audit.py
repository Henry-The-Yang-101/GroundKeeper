"""Validate six blind audit returns and expose disagreements for adjudication."""
import json

from groundkeeper.policy import validate_answer
from scripts.full_common import read_rows,write_json
from scripts.prepare_v2_training import OUT,PUBLIC,FIELDS


def collect():
    selection=json.loads((OUT/'new-audit/selection.json').read_text())
    originals={r['id']:r for split in ('train','valid')
               for r in read_rows(OUT/f'draft/{split}_records.jsonl')}
    results=[];differences=[]
    for packet in range(6):
        inputs=read_rows(OUT/f'new-audit/packet_{packet:02d}.jsonl')
        labels=read_rows(OUT/f'new-audit/packet_{packet:02d}_labels.jsonl')
        if len(labels)!=25 or [r['id'] for r in labels]!=[r['id'] for r in inputs]:
            raise ValueError('Incomplete independent audit packet')
        for label in labels:
            if set(label)!=FIELDS or label['disposition'] not in ('keep','reject'):
                raise ValueError('Invalid audit annotation')
            if not all(isinstance(label[k],str) and label[k].strip() for k in ('merchant_group','evidence')):
                raise ValueError('Empty audit evidence/group')
            answer={k:label[k] for k in ('type','category','review')}
            validate_answer(answer)
            original=originals[label['id']]
            results.append(label)
            if answer!=original['answer'] or label['disposition']=='reject':
                differences.append({'id':label['id'],'input':original['input'],
                    'original':original['answer'],'independent':answer,
                    'independent_disposition':label['disposition'],'evidence':label['evidence']})
    if {r['id'] for r in results}!=set(selection['ids']):
        raise ValueError('Independent audit selection mismatch')
    return selection,results,differences


def verify_completed():
    selection,results,differences=collect()
    audit=json.loads((PUBLIC/'new_label_audit.json').read_text())
    if not audit.get('complete') or set(audit.get('reviewed_ids',[]))!=set(selection['ids']):
        raise ValueError('Audit completion/coverage mismatch')
    decisions=audit.get('decisions',{})
    for row in differences:
        decision=decisions.get(row['id'],{})
        if not decision.get('reason') or not (decision.get('reject') or 'answer' in decision):
            raise ValueError(f'Unresolved independent audit disagreement: {row["id"]}')
        if not decision.get('reject'):
            validate_answer(decision['answer'])
    # The decisions are the actual overrides, including explicit retain-original
    # decisions; no unaudited extra edits can be smuggled into a second map.
    if audit.get('adjudications',{})!=decisions:
        raise ValueError('Adjudications must match the reviewed decision journal')
    return audit


def main():
    selection,results,differences=collect()
    report={'audited':len(results),'agreement':len(results)-len(differences),
            'disagreements':differences,'reviewed_ids':selection['ids']}
    write_json(OUT/'new-audit/disagreements.json',report)
    print(json.dumps(report,indent=2))


if __name__=='__main__':
    main()
