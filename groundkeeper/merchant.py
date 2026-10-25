"""Confirmed memory over a caller-owned unlocked connection; no plaintext export.

Use an in-memory SQLite connection for public experiments. Production must inject
its unlocked SQLCipher connection. The locked nightly worker passes None and has
no access to personal rules. This module does not open files or obtain keys.
"""
import json,re,unicodedata
from dataclasses import dataclass
from datetime import datetime
from rapidfuzz.fuzz import ratio
from .policy import CATEGORIES,validate_answer


def normalize(raw):
    text=unicodedata.normalize('NFKC',raw).casefold().strip()
    text=re.sub(r'^(?:(?:sq|tst|clv|pp|pypl|paypal)\s*\*\s*)+','',text)
    # Do not erase numbers, service qualifiers, arbitrary trailing words, or raw.
    return re.sub(r'\s+',' ',text)


def timestamp(value):
    parsed=datetime.fromisoformat(value.replace('Z','+00:00'))
    if parsed.tzinfo is None:raise ValueError('Confirmation/as-of timestamp must be timezone aware')
    return parsed.timestamp()

@dataclass(frozen=True)
class FuzzyPolicy:
    threshold:float=96.0
    margin:float=8.0
    calibrated:bool=False
    def __post_init__(self):
        if not 0<=self.threshold<=100 or not 0<=self.margin<=100:raise ValueError('Invalid fuzzy thresholds')

class MerchantMemory:
    def __init__(self,connection=None,fuzzy=FuzzyPolicy()):
        self.connection=connection;self.fuzzy=fuzzy
        if connection is not None:
            connection.executescript('''
            CREATE TABLE IF NOT EXISTS gk_confirmations(
              id INTEGER PRIMARY KEY, raw TEXT NOT NULL, alias TEXT NOT NULL,
              category TEXT NOT NULL, scope TEXT NOT NULL,
              transaction_id TEXT, confirmed_at REAL NOT NULL,
              actor TEXT NOT NULL, merchant_id TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS gk_confirmation_audit(
              id INTEGER PRIMARY KEY, confirmation_id INTEGER NOT NULL,
              event TEXT NOT NULL, at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS gk_public_references(
              alias TEXT NOT NULL, merchant_id TEXT NOT NULL, source TEXT NOT NULL);
            ''')
    def confirm(self,raw,category,confirmed_at,transaction_id=None,*,merchant_scope=False,actor='user',merchant_id=None):
        if self.connection is None:raise PermissionError('Merchant memory is locked')
        if category not in CATEGORIES:raise ValueError('Confirm a supported category')
        if not merchant_scope and not transaction_id:raise ValueError('Purchase correction needs transaction_id')
        alias=normalize(raw)
        if not alias:raise ValueError('Empty alias')
        when=timestamp(confirmed_at)
        with self.connection:
            row=self.connection.execute('INSERT INTO gk_confirmations(raw,alias,category,scope,transaction_id,confirmed_at,actor,merchant_id) VALUES(?,?,?,?,?,?,?,?)',(raw,alias,category,'merchant' if merchant_scope else 'transaction',transaction_id,when,actor,merchant_id or alias))
            self.connection.execute('INSERT INTO gk_confirmation_audit(confirmation_id,event,at) VALUES(?,?,?)',(row.lastrowid,'explicit_merchant_rule' if merchant_scope else 'purchase_only_correction',when))
    def add_reference(self,raw,merchant_id,source):
        if self.connection is None:raise PermissionError('Merchant memory is locked')
        with self.connection:self.connection.execute('INSERT INTO gk_public_references VALUES(?,?,?)',(normalize(raw),merchant_id,source))
    def lookup(self,raw,as_of,transaction_id=None):
        if self.connection is None:return None
        when=timestamp(as_of);alias=normalize(raw)
        if not alias:return None
        rows=self.connection.execute('SELECT alias,category,scope,transaction_id,confirmed_at,merchant_id FROM gk_confirmations WHERE confirmed_at<=? ORDER BY confirmed_at DESC,id DESC',(when,)).fetchall()
        # The newest correction for one purchase wins; it cannot escape that ID.
        for r in rows:
            if transaction_id and r[2]=='transaction' and r[3]==transaction_id:
                return {'category':r[1],'review':False,'method':'confirmed_transaction'}
        # Newer same-alias rules supersede older ones. Different aliases remain.
        rules={}
        for r in rows:
            if r[2]=='merchant':rules.setdefault(r[0],r)
        if alias in rules:return {'category':rules[alias][1],'review':False,'method':'confirmed_exact'}
        # Public reference table is deliberately excluded. Competing identities
        # are collapsed per merchant before applying the runner-up margin.
        ranked={}
        for key,r in rules.items():
            score=ratio(alias,key)
            identity=(r[5],r[1])
            if identity not in ranked or score>ranked[identity][0]:ranked[identity]=(score,r[1])
        ranked=sorted(ranked.values(),reverse=True)
        if not ranked:return None
        best=ranked[0];runner=ranked[1][0] if len(ranked)>1 else 0
        if best[0]<self.fuzzy.threshold or best[0]-runner<self.fuzzy.margin:return None
        return {'category':best[1],'review':not self.fuzzy.calibrated,'method':'confirmed_fuzzy','score':best[0],'runner_up_margin':best[0]-runner}

def classify(inputs,memory,model,*,as_of,transaction_id=None):
    # Only known debit purchases may use spending memory; all financial-type
    # text goes to the typed model/review branch, never through a merchant rule.
    raw=inputs['description']
    financial=re.search(r'\b(refund|payroll|deposit|transfer|mortgage|principal|installment|payment to card|card payment|cash withdrawal|balance adjustment)\b',raw,re.I)
    match=memory.lookup(raw,as_of,transaction_id) if inputs['direction']=='debit' and not financial else None
    if match:return {'type':'expense',**{k:match[k] for k in ('category','review')},'method':match['method']}
    result=validate_answer(model(inputs));result={**result,'review':True}
    return {**result,'method':'model_review'}
