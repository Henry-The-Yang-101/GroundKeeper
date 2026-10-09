import sqlite3
import pytest
from groundkeeper.merchant import MerchantMemory,FuzzyPolicy,normalize,classify

T0='2026-01-01T00:00:00Z';T1='2026-02-01T00:00:00Z';T2='2026-03-01T00:00:00Z'
def store(**kw):return MerchantMemory(sqlite3.connect(':memory:'),**kw)
def test_locked_rules_are_unavailable():
 m=MerchantMemory();assert m.lookup('Amazon',T1) is None
 with pytest.raises(PermissionError):m.confirm('Amazon','gifts',T0,transaction_id='x')
def test_purchase_correction_does_not_become_merchant_rule():
 m=store();m.confirm('Amazon','gifts',T0,transaction_id='a')
 assert m.lookup('Amazon',T1,'a')['category']=='gifts'
 assert m.lookup('Amazon',T1,'b') is None
 assert m.lookup('Amazon',T1) is None
def test_future_confirmation_never_leaks():
 m=store();m.confirm('Loblaws','groceries',T2,merchant_scope=True)
 assert m.lookup('Loblaws',T1) is None
 assert m.lookup('Loblaws',T2)['category']=='groceries'
def test_public_reference_is_not_confirmation():
 m=store();m.add_reference('SQ *CAFE','cafe','public.csv')
 assert m.lookup('SQ *CAFE',T1) is None
def test_normalization_preserves_service_and_number_tokens():
 assert normalize('SQ *  Cafe')=='cafe'
 assert normalize('UBER EATS')!=normalize('UBER TRIP')
 assert normalize('7 ELEVEN')!=normalize('ELEVEN')
 assert normalize('COSTCO GAS #4')!=normalize('COSTCO PHARMACY #4')
def test_fuzzy_near_tie_abstains_and_uncalibrated_stays_review():
 m=store(fuzzy=FuzzyPolicy(70,8));m.confirm('Cafe Alpha','dining',T0,merchant_scope=True)
 m.confirm('Cafe Alphi','shopping',T0,merchant_scope=True)
 assert m.lookup('Cafe Alph',T1) is None
 n=store(fuzzy=FuzzyPolicy(70,8));n.confirm('Cafe Alpha','dining',T0,merchant_scope=True)
 assert n.lookup('Cafe Alph',T1)['review'] is True
def test_credit_and_model_predictions_require_review():
 m=store();m.confirm('Cafe','dining',T0,merchant_scope=True)
 model=lambda _: {'type':'unknown','category':'uncategorized','review':True}
 result=classify({'description':'Cafe','direction':'credit','currency':'CAD'},m,model,as_of=T1)
 assert result['method']=='model_review'
def test_same_chain_different_purposes_still_compete():
 m=store(fuzzy=FuzzyPolicy(70,8));m.confirm('Shop Alpha','groceries',T0,merchant_scope=True,merchant_id='same-chain')
 m.confirm('Shop Alphi','medical',T0,merchant_scope=True,merchant_id='same-chain')
 assert m.lookup('Shop Alph',T1) is None
