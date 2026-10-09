"""Local-only MLX runtime using the exact experiment schema and chat template."""
import json,os,time
from pathlib import Path
from .policy import messages,validate_answer,safe_prediction,parse_answer

def generate_answer(model,tokenizer,inputs,max_tokens=96):
    from mlx_lm import generate
    from mlx_lm.sample_utils import make_sampler
    prompt=tokenizer.apply_chat_template(messages(inputs),tokenize=False,add_generation_prompt=True,enable_thinking=False)
    start=time.perf_counter()
    text=generate(model,tokenizer,prompt=prompt,max_tokens=max_tokens,sampler=make_sampler(0))
    try:answer=parse_answer(text);valid=True
    except (ValueError,TypeError):answer=safe_prediction(text);valid=False
    return answer,{'raw':text,'valid_schema':valid,'removed_json_fence':text.strip().startswith('```'),'latency_seconds':time.perf_counter()-start}

class LocalCategorizer:
    def __init__(self,model_path,adapter_path=None):
        # Require complete local paths before the model loader can run. No remote
        # identifiers are accepted and hub access stays disabled for this process.
        model_path=Path(model_path)
        if not (model_path/'config.json').is_file() or not list(model_path.glob('*.safetensors')):
            raise ValueError('Expected a local model directory')
        if adapter_path is not None and not (Path(adapter_path)/'adapters.safetensors').is_file():
            raise ValueError('Expected local adapters')
        os.environ['HF_HUB_OFFLINE']='1';os.environ['HF_HUB_DISABLE_TELEMETRY']='1'
        from mlx_lm import load
        self.model,self.tokenizer=load(str(model_path),adapter_path=str(adapter_path) if adapter_path else None)
    def suggest(self,inputs):
        answer,_=generate_answer(self.model,self.tokenizer,inputs)
        # No private held-out calibration exists; never auto-confirm model output.
        return {**answer,'review':True}
