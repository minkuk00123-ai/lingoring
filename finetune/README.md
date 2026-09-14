# On-device conversation model — fine-tuning pipeline

Produces the GGUF model `LlamaConversationService`
(`lib/core/services/llama_conversation_service.dart`) loads on-device,
replacing the NVIDIA cloud call so the conversation feature has no shared
API quota and works fully offline after the first download.

Base model: `Qwen/Qwen2.5-1.5B-Instruct` (Apache-2.0, ungated — no HF login
needed). Chosen over the Llama 3.2 1B/3B and Gemma 3 4B candidates because
it's ungated (no manual license click blocking automation) and small enough
for real-time CPU inference on a phone.

## Pipeline

```bash
python3.12 -m venv .venv && source .venv/bin/activate
pip install mlx-lm huggingface_hub datasets python-dotenv requests
brew install llama.cpp   # for llama-quantize

# 1. Generate synthetic training data by sampling the *production* system
#    prompt/JSON format through the existing NVIDIA teacher API (needs
#    NVIDIA_API_KEY in ../.env). Writes data/{train,valid,test}.jsonl.
python generate_data.py 180   # arg = number of synthetic conversations

# 2. LoRA fine-tune on Apple Silicon via MLX. Writes adapters/.
./train.sh

# 3. Fuse the adapter into the base weights, export GGUF, quantize to
#    Q4_K_M. Writes gguf/lingoring-conversation-q4_k_m.gguf (~1GB).
./export.sh
```

## Wiring the result into the app

`LlamaConversationService.modelSource` (in the Dart file above) is read
from `--dart-define=LINGORING_LLM_MODEL_SOURCE=...` at build/run time —
`ModelSource.parse()` treats it as a local path, an `https://` URL (download
once, then cached on-device — same pattern as `WhisperSttService`), or an
`hf://` Hugging Face reference.

- **Local dev/testing**: push the GGUF to the emulator/device and pass its
  on-device path, e.g.
  `adb push gguf/lingoring-conversation-q4_k_m.gguf /data/local/tmp/` then
  `flutter run --dart-define=LINGORING_LLM_MODEL_SOURCE=/data/local/tmp/lingoring-conversation-q4_k_m.gguf`.
- **Shipping**: hosted on GitHub Releases —
  `https://github.com/minkuk00123-ai/lingoring/releases/download/v0.1.0-model/lingoring-conversation-q4_k_m.gguf`
  is baked in as `LlamaConversationService.modelSource`'s default, so a
  plain `flutter build apk --release` already points at it; real installs
  download it on first launch and cache it, same as the whisper.cpp model.
  To ship a retrained model, upload a new release asset (see `export.sh`'s
  output) and update that default (or pass
  `--dart-define=LINGORING_LLM_MODEL_SOURCE=<new URL>` at build time).

## Retraining

Re-run `generate_data.py` with a larger N for more data, or edit its
`TOPICS`/`MISTAKE_HINTS` lists to cover more scenarios, then re-run
`train.sh` and `export.sh`. `train.sh` takes `ITERS=<n>` as an env var to
change training length (default 400).
