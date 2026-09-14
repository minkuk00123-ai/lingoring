"""Generates synthetic LoRA training data for the on-device conversation
model by sampling many (learner utterance -> {reply, correction}) turns from
the same NVIDIA-hosted teacher model (meta/llama-3.2-11b-vision-instruct)
the app currently calls directly over the network, using the exact system
prompt and JSON output shape from lib/core/services/conversation_service.dart
so the student model learns the identical task/format, not just English
conversation in general.

Two passes per example:
  1. Ask the teacher to invent a short, varied English-learner utterance
     (a mix of correct and mistake-containing sentences, across everyday
     topics) — this is the synthetic "user turn".
  2. Feed that utterance through the *actual* production system prompt to
     get the {"reply": ..., "correction": ...} the app itself would produce.

Output: JSONL at finetune/data/{train,valid}.jsonl in mlx_lm chat format
(a list of {role, content} messages per line, keyed "messages" — mlx_lm's
--data loader reads this directly for chat-style fine-tuning).
"""

import json
import os
import random
import sys
import time
from pathlib import Path

import dotenv
import requests

ROOT = Path(__file__).resolve().parent.parent
dotenv.load_dotenv(ROOT / ".env")

API_KEY = os.environ.get("NVIDIA_API_KEY", "").strip()
if not API_KEY:
    sys.exit("NVIDIA_API_KEY not set in .env — cannot generate training data.")

BASE_URL = "https://integrate.api.nvidia.com/v1/chat/completions"
MODEL = "meta/llama-3.2-11b-vision-instruct"

# Must match lib/core/services/conversation_service.dart _systemPrompt
# exactly — the student is learning this production task, not a
# paraphrase of it.
SYSTEM_PROMPT = (
    'You are a friendly English conversation partner for a Korean learner '
    'practicing spoken English. Reply with ONLY a single-line JSON object '
    'of the exact shape {"reply": "...", "correction": "..."} — no markdown '
    'fences, no text outside the JSON. Keep "reply" short (1-3 sentences), '
    'use simple everyday vocabulary, and just continue the conversation '
    'naturally — never mention grammar, corrections, or explain anything '
    'inside "reply" itself. If the user\'s last message had an English '
    'mistake, put ONLY the corrected version of their sentence in '
    '"correction"; otherwise set "correction" to an empty string. Always '
    'reply in English only.'
)

TOPICS = [
    "ordering food at a restaurant", "talking about the weekend", "a job interview",
    "asking for directions", "talking about hobbies", "shopping for clothes",
    "planning a trip", "talking about family", "describing your daily routine",
    "talking about movies or TV shows", "small talk at work", "making a phone call",
    "talking about health and exercise", "discussing the weather", "making plans with a friend",
    "talking about school or studying", "ordering coffee", "checking into a hotel",
    "talking about pets", "discussing favorite food", "asking for help at a store",
    "talking about technology", "discussing a recent news story", "talking about music",
    "apologizing for being late", "introducing yourself to someone new",
    "talking about a problem at work", "asking someone about their weekend plans",
    "talking about sports", "describing your hometown",
]

MISTAKE_HINTS = [
    "with a common Korean-English learner grammar mistake (e.g. verb tense, articles, prepositions, subject-verb agreement, plurals)",
    "with a natural, correctly-written sentence (no mistake)",
    "with a small vocabulary or word-choice mistake",
    "with a common learner mistake, and keep it a single short sentence",
]


def call_teacher(messages, max_tokens=200, temperature=1.0):
    for attempt in range(5):
        try:
            res = requests.post(
                BASE_URL,
                headers={"Authorization": f"Bearer {API_KEY}"},
                json={
                    "model": MODEL,
                    "messages": messages,
                    "temperature": temperature,
                    "top_p": 0.95,
                    "max_tokens": max_tokens,
                    "stream": False,
                },
                timeout=60,
            )
            if res.status_code == 429:
                time.sleep(3 * (attempt + 1))
                continue
            res.raise_for_status()
            content = res.json()["choices"][0]["message"]["content"].strip()
            return content
        except Exception as e:  # noqa: BLE001
            print(f"  retry {attempt} after error: {e}", file=sys.stderr)
            time.sleep(2 * (attempt + 1))
    return None


def strip_json_fence(s: str) -> str:
    s = s.strip()
    if s.startswith("```"):
        s = s[3:]
        if s.startswith("json"):
            s = s[4:]
        end = s.rfind("```")
        if end != -1:
            s = s[:end]
    return s.strip()


def gen_user_turn(topic: str, mistake_hint: str, history_hint: str) -> str | None:
    prompt = (
        f"Invent ONE short thing a Korean English-learner (intermediate level) "
        f"might say out loud in a spoken conversation about '{topic}'. "
        f"Write it {mistake_hint}. {history_hint} "
        f"Output ONLY the sentence itself, no quotes, no explanation, no labels."
    )
    out = call_teacher(
        [
            {"role": "system", "content": "You generate realistic spoken-English practice sentences for a dataset. Reply with only the requested sentence."},
            {"role": "user", "content": prompt},
        ],
        max_tokens=60,
        temperature=1.05,
    )
    if not out:
        return None
    # Strip surrounding quotes the model sometimes adds anyway.
    out = out.strip().strip('"').strip("'").strip()
    return out or None


def gen_teacher_reply(history: list[dict]) -> dict | None:
    messages = [{"role": "system", "content": SYSTEM_PROMPT}] + history
    out = call_teacher(messages, max_tokens=200, temperature=0.6)
    if not out:
        return None
    try:
        data = json.loads(strip_json_fence(out))
        reply = (data.get("reply") or "").strip()
        if not reply:
            return None
        correction = (data.get("correction") or "").strip()
        return {"reply": reply, "correction": correction}
    except Exception:
        return None


def build_conversation(min_turns=1, max_turns=3) -> list[dict] | None:
    """Builds one multi-turn synthetic conversation (list of user/assistant
    dicts with plain text, matching ConversationTurn's shape) by chaining
    gen_user_turn -> gen_teacher_reply repeatedly, feeding the assistant's
    own prior replies back in as history — this is what teaches the model
    to hold a coherent conversation, not just answer single turns."""
    topic = random.choice(TOPICS)
    n_turns = random.randint(min_turns, max_turns)
    turns = []  # list of {"role": "user"/"assistant", "content": str}
    for i in range(n_turns):
        mistake_hint = random.choice(MISTAKE_HINTS)
        history_hint = (
            "This is the start of a new conversation."
            if i == 0
            else f"This continues the conversation naturally, replying to: \"{turns[-1]['content']}\""
        )
        user_text = gen_user_turn(topic, mistake_hint, history_hint)
        if not user_text:
            continue
        turns.append({"role": "user", "content": user_text})

        reply = gen_teacher_reply(turns)
        if not reply:
            turns.pop()
            continue
        # correction is UI-only, never fed back as conversation history —
        # matches ConversationService.reply's own history-building logic.
        turns.append({"role": "assistant", "content": reply["reply"], "correction": reply["correction"]})
    if len(turns) < 2:
        return None
    return turns


def to_mlx_chat_example(turns: list[dict]) -> dict:
    """One training example per assistant turn, with the system prompt +
    preceding history as context — teaches the exact same task the app's
    ConversationService.reply() performs, output format included."""
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    for t in turns:
        if t["role"] == "user":
            messages.append({"role": "user", "content": t["content"]})
        else:
            target = json.dumps(
                {"reply": t["content"], "correction": t.get("correction", "")},
                ensure_ascii=False,
            )
            messages.append({"role": "assistant", "content": target})
    return {"messages": messages}


def main():
    n_conversations = int(sys.argv[1]) if len(sys.argv) > 1 else 220
    out_dir = ROOT / "finetune" / "data"
    out_dir.mkdir(parents=True, exist_ok=True)

    examples = []
    for i in range(n_conversations):
        turns = build_conversation()
        if not turns:
            print(f"[{i+1}/{n_conversations}] skipped (empty)")
            continue
        # Emit one training example per assistant reply within the
        # conversation (i.e. with 1, 2, 3... turns of preceding history),
        # not just the final full conversation — more training signal per
        # generated conversation, and covers both short- and long-context
        # replies.
        running = []
        for t in turns:
            running.append(t)
            if t["role"] == "assistant":
                examples.append(to_mlx_chat_example(running))
        print(f"[{i+1}/{n_conversations}] +{sum(1 for t in turns if t['role']=='assistant')} examples (total {len(examples)})")

    random.shuffle(examples)
    n_valid = max(20, len(examples) // 10)
    valid, train = examples[:n_valid], examples[n_valid:]

    with open(out_dir / "train.jsonl", "w") as f:
        for ex in train:
            f.write(json.dumps(ex, ensure_ascii=False) + "\n")
    with open(out_dir / "valid.jsonl", "w") as f:
        for ex in valid:
            f.write(json.dumps(ex, ensure_ascii=False) + "\n")
    # mlx_lm also expects a test.jsonl to exist if --test is passed; reuse
    # a slice of valid so evaluation has something to read.
    with open(out_dir / "test.jsonl", "w") as f:
        for ex in valid[: max(10, len(valid) // 2)]:
            f.write(json.dumps(ex, ensure_ascii=False) + "\n")

    print(f"\nWrote {len(train)} train / {len(valid)} valid examples to {out_dir}")


if __name__ == "__main__":
    main()
