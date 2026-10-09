import pytest

from scripts.prepare_v2_training import allocate, cap_variants, coverage, entity_group, normalized_group, EXTRA_ALIASES, BANK_ALIASES


def row(rid, group, text='purchase', typ='expense', category='dining', **kw):
    return {'id':rid,'merchant_group':group,'input':{'description':text,'direction':'debit','currency':'USD'},
            'answer':{'type':typ,'category':category,'review':False},'source':'test',**kw}


def test_bank_identity_does_not_merge_all_loan_purposes():
    a = row('a','generic:loan','BANK OF AMERICA LOAN PRINCIPAL ONLY')
    b = row('b','generic:loan','CITIBANK LOAN PRINCIPAL ONLY')
    assert entity_group(a,a)=='bankofamerica'
    assert entity_group(b,b)=='citibank'


def test_duplicate_component_with_conflicting_anchors_is_excluded():
    a=row('a','merchant-a','Merchant bill ref 123',legacy_training=True)
    b=row('b','merchant-b','MERCHANT BILL REF 999',planned_split='valid')
    retained, excluded=allocate([a,b],[])
    assert not retained and len(excluded)==2
    assert all(r['reason']=='conflicting_partition_anchors' for r in excluded)


def test_test_merchant_never_returns_in_v2_and_valid_never_trains():
    rows=[row('a','wellsfargo'),row('b','allybank','another purchase')]
    manifest=[{'group':'wellsfargo','split':'test','input_sha256':'unused'},
              {'group':'allybank','split':'valid','input_sha256':'unused'}]
    retained, excluded=allocate(rows,manifest)
    assert [(r['id'],r['split']) for r in retained]==[('b','valid')]
    assert excluded[0]['reason']=='v1_final_test_merchant'


def test_short_brand_alias_still_excludes_a_prior_test_merchant():
    r=row('a',normalized_group('orangetheory'))
    manifest=[{'group':'orangetheoryfitness','split':'test','input_sha256':'unused'}]
    retained,excluded=allocate([r],manifest)
    assert not retained and excluded[0]['reason']=='v1_final_test_merchant'
    assert normalized_group('citizensbank')!=normalized_group('citibank')
    assert normalized_group('collegeofnewark')!=normalized_group('collegeofnewyork')
    assert normalized_group('experian')!=normalized_group('expedia')


def test_alias_resolution_is_idempotent_across_multiple_hops():
    assert normalized_group('escaperoomco')=='generic:escaperoom'
    for group in (*EXTRA_ALIASES,*BANK_ALIASES):
        resolved=normalized_group(group)
        assert normalized_group(resolved)==resolved


def test_bank_variants_keep_distinct_types_instead_of_global_cap_six():
    types=['income','transfer','card_payment','loan_principal','cash_movement','balance_adjustment','refund']
    rows=[row(str(i),'bank',f'{typ} wording {variant}',typ,None)
          for i,(typ,variant) in enumerate((t,v) for t in types for v in ['a','b'])]
    retained, excluded=cap_variants(rows)
    assert len(retained)==14 and not excluded


def test_conflicting_labels_on_normalized_duplicate_fail_closed():
    with pytest.raises(ValueError,match='Conflicting normalized'):
        cap_variants([row('a','shop','SHOP 123'),row('b','shop','shop 999',category='shopping')])


def test_coverage_gate_identifies_missing_types_and_categories():
    with pytest.raises(ValueError,match='type transfer'):
        coverage({'train':[row('a','shop')]})
