#!/bin/bash
# LoRA fine-tunes the on-device conversation model (Qwen2.5-1.5B-Instruct)
# on the synthetic data from generate_data.py, using MLX (Apple Silicon).
# Run from finetune/ with the venv active, after data/{train,valid,test}.jsonl
# exist. Output adapter goes to finetune/adapters/.
set -euo pipefail
cd "$(dirname "$0")"
source .venv/bin/activate

MODEL="Qwen/Qwen2.5-1.5B-Instruct"

mlx_lm.lora \
  --model "$MODEL" \
  --train \
  --data ./data \
  --adapter-path ./adapters \
  --fine-tune-type lora \
  --num-layers 16 \
  --batch-size 4 \
  --iters "${ITERS:-400}" \
  --learning-rate 1e-5 \
  --steps-per-report 10 \
  --steps-per-eval 50 \
  --save-every 100 \
  --max-seq-length 1024 \
  --mask-prompt \
  --test \
  --seed 0
