#!/bin/bash
# Fuses the trained LoRA adapter into the base model, exports GGUF (f16),
# then quantizes to Q4_K_M for on-device use. Run after train.sh finishes.
# Output: finetune/gguf/lingoring-conversation-q4_k_m.gguf
set -euo pipefail
cd "$(dirname "$0")"
source .venv/bin/activate

MODEL="Qwen/Qwen2.5-1.5B-Instruct"
mkdir -p gguf

# mlx_lm.fuse's own --export-gguf only supports llama/mixtral/mistral
# architectures (see mlx_lm/fuse.py) — Qwen2 isn't in that list, even
# though llama.cpp itself supports Qwen2 GGUF fine. So: fuse to a plain
# HF-format checkpoint here, then hand that to llama.cpp's own
# convert_hf_to_gguf.py (cloned into llama.cpp-src/) for the actual GGUF
# export below.
echo "Fusing adapter into HF-format checkpoint..."
mlx_lm.fuse \
  --model "$MODEL" \
  --adapter-path ./adapters \
  --save-path ./fused \
  --dequantize

echo "Converting fused checkpoint to f16 GGUF via llama.cpp..."
python3 llama.cpp-src/convert_hf_to_gguf.py \
  ./fused \
  --outfile ./gguf/lingoring-conversation-f16.gguf \
  --outtype f16

echo "Quantizing to Q4_K_M..."
llama-quantize \
  ./gguf/lingoring-conversation-f16.gguf \
  ./gguf/lingoring-conversation-q4_k_m.gguf \
  Q4_K_M

ls -lh ./gguf/
echo "Done: finetune/gguf/lingoring-conversation-q4_k_m.gguf"
