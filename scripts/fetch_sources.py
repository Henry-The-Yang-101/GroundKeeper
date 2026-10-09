"""Download only pinned public source files; respects Hugging Face gating."""
from pathlib import Path
from huggingface_hub import hf_hub_download
SOURCES={
 'DoDataThings/us-bank-transaction-categories-v2':('3e8d052cb7b362fb1a04b6064d2331982553ea56',['README.md','transactions-synthetic.csv']),
 'crossingminds/credit_card_3k':('dcb5e807abb9cce5858ebcfee509c224c85bb860',['README.md','data.csv']),
 'mitulshah/transaction-categorization':('8597493f0aaa44c540c16458b18b17e4ada2f5cc',['README.md','categories.json','dataset_info.json','default/train/0000.parquet'])}
for repo,(revision,names) in SOURCES.items():
 for name in names:
  try:
   hf_hub_download(repo_id=repo,repo_type='dataset',filename=name,revision=revision,local_dir=Path('.local/finetune/sources')/repo.split('/')[0])
   print(repo,name,'downloaded',flush=True)
  except Exception as e: print(repo,name,type(e).__name__,flush=True);raise
