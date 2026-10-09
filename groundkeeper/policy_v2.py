"""V2 prompt and canonical target order; v1 artifacts remain unchanged."""
import json
from .policy import SYSTEM, validate_input, validate_answer

SYSTEM_V2 = SYSTEM + '''
Explicit credited payroll/benefits/earnings/interest=>income,null. Cash adjustment=>balance_adjustment,null; ATM withdrawal=>cash_movement,null. Debit 'withdrawal from' a named merchant is a purchase wrapper. Household waste/recycling=>utilities. Standalone shipping fee=>other. Annual/monthly service fee without bank/account/card or service evidence=>expense,uncategorized,review=true. Purpose beats address words. Review concerns decision uncertainty, not merely an unfamiliar payer name. Output keys in order: type,category,review.'''


def messages_v2(inputs, answer=None):
    validate_input(inputs)
    result = [{'role':'system','content':SYSTEM_V2},
              {'role':'user','content':json.dumps(inputs,separators=(',',':'),ensure_ascii=False)}]
    if answer is not None:
        validate_answer(answer)
        canonical = {key:answer[key] for key in ('type','category','review')}
        result.append({'role':'assistant','content':json.dumps(canonical,separators=(',',':'))})
    return result
