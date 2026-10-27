from groundkeeper import runtime_v2


class Tokenizer:
    def apply_chat_template(self, *args, **kwargs):
        return [1, 2]


INPUT = {'description':'CAFE MEAL','direction':'debit','currency':'CAD'}


def test_valid_draft_is_preserved_without_retry(monkeypatch):
    monkeypatch.setattr(runtime_v2,'_generate_draft',lambda *a,**k:'{"type":"expense","category":"dining","review":false}')
    def forbidden(*args,**kwargs):
        raise AssertionError('A valid draft must not be regenerated')
    monkeypatch.setattr(runtime_v2,'generate_constrained',forbidden)
    answer, detail = runtime_v2.generate_decision(None,Tokenizer(),INPUT,object(),mode='validated_retry')
    assert answer['category']=='dining' and not detail['constrained_retry']


def test_invalid_field_combination_uses_constrained_retry(monkeypatch):
    draft='{"type":"income","category":"income","review":false}'
    monkeypatch.setattr(runtime_v2,'_generate_draft',lambda *a,**k:draft)
    monkeypatch.setattr(runtime_v2,'generate_constrained',lambda *a,**k:(
        {'type':'income','category':None,'review':False},
        {'raw':'{"type":"income","category":null,"review":false}','valid_schema':True}))
    answer, detail=runtime_v2.generate_decision(None,Tokenizer(),INPUT,object(),mode='validated_retry')
    assert answer['category'] is None and detail['constrained_retry'] and detail['draft_raw']==draft


def test_application_review_override_does_not_change_model_training_target(monkeypatch):
    monkeypatch.setattr(runtime_v2,'generate_decision',lambda *a,**k:(
        {'type':'expense','category':'dining','review':False},{}))
    runtime=runtime_v2.StructuredCategorizer.__new__(runtime_v2.StructuredCategorizer)
    runtime.model=None;runtime.tokenizer=None;runtime.grammar=None
    runtime.mode='constrained';runtime.builder=None
    assert runtime.suggest(INPUT)=={'type':'expense','category':'dining','review':True}
