# Interleaved chat → classifier produces zero classifier_logits

## Reproducer (Mac, ~30 sec)

```bash
bazelisk build --config=macos_arm64 \
  --disk_cache=$HOME/.cache/bazel-mac-classify -c opt \
  //runtime/engine:litert_lm_e2e_test_main

bazel-bin/runtime/engine/litert_lm_e2e_test_main \
  --model_path=.../model.litertlm \
  --lora_path=.../lora_adapter.tflite \
  --backend=cpu \
  --iterations=1 \
  --mode=interleave
```

Output:

```
[e2e] iter=0 phase=interleave classifier logits insane: 0 0 0 0
[e2e] done. failures=1/2
```

vs. `--mode=classifier_only` which produces real logits.

## What the trace logs prove

For the **classifier session's single decode step**:

| Log line | Value |
|---|---|
| `[LoRA-DBG] CreateContextHandler` | `has_scoped_lora=true executor_current_lora_id=0` ✓ |
| `[LoRA-DBG] BindTensorsAndRunPrefill` | `signature=prefill_128 context_lora_id=0 lora_manager_set=true` ✓ |
| `[STEP-DBG] Decode entry` | `current_step=45 max_num_tokens=1024 max_output_tokens=1` ✓ |
| `[DBG] DecodeLogits enter` | `current_step=45 ran_decode=false` ✓ |
| `[LoRA-DBG] BindTensorsAndRunDecode` | `signature=decode context_lora_id=0 lora_manager_set=true` ✓ |
| `[AUX-DBG] pre-decode classifier_logits` | `[0, 0, 0, 0]` |
| `[AUX-DBG] post-decode classifier_logits` | **`[0, 0, 0, 0]`** ← bug |

Every plumbing layer is correct: the session has LoRA, the executor's
per-context lora_id is set, the runtime invokes decode with LoRA buffers
merged. **But the model graph itself produces no classifier_logits
output.**

The same decode call in `--mode=classifier_only`:

```
[AUX-DBG] pre-decode classifier_logits  [0, 0, 0, 0]
[AUX-DBG] post-decode classifier_logits [-0.408, -0.214, -0.792, -0.776]
```

→ post-decode is non-zero. Identical decode path, identical LoRA
binding. Only difference: classifier_only runs as the first decode call
on the engine. Interleave runs after chat's many decodes.

## Suspect

The compiled tflite graph for gemma-4-e4b-it-bouncer has a classifier
head sub-graph whose activation depends on executor-level state that
persists across sessions but isn't part of the per-session LlmContext —
likely:

- `input_kv_cache_buffers_` / `output_kv_cache_buffers_` pointer state
  after the std::swap in BindTensorsAndRunDecode / Prefill.
- `decode_input_buffers_` / `decode_output_buffers_` entries that hold
  cached compiled-model pointers.
- A LiteRT-internal cache (delegate-specific) that fixes which named
  outputs are activated after the first inference on an engine.

Tried: force-reset of input_kv_cache_buffers_ in RestoreContext even
when current_step==0 (reverted — broke decode entirely; the runtime
needs the existing buffers to be valid). So the swap state is involved
but more carefully than a blanket reset.

A proper fix needs visibility into the gemma4 compiled graph and the
LiteRT delegate's named-output management — out of scope for an external
patch.

## Practical workaround for iOS / Bouncer

Use **two engine instances**: one for chat, one for classifier. Each
holds its own `LlmLiteRtCompiledModelExecutorBase` with isolated kv
cache / output-buffer state. The 3.9 GB model file is mmap'd from disk
so the duplicated engine doesn't double RAM cost (only the per-engine
state structures duplicate).

In `LocalInferenceService.swift`:

```swift
private var chatEngine: Engine?
private var classifyEngine: Engine?
```

Build both lazily in `ensureReady`. Use `chatEngine` for `classify()`
and `classifyEngine` for `classifyText()`. The base Conversation for
chat lives on `chatEngine`; the per-call classifier conversation on
`classifyEngine`.

Confirmed locally that `classifier_only` and `classifier_after_chat`
both produce real logits when the engine has never run a chat decode
loop. So a dedicated `classifyEngine` will keep classifier_logits sane.
