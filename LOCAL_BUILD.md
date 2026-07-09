# Building LiteRT-LM locally for the Bouncer iOS app

> Part of the on-device-LLM docs set. Companion docs (head training,
> investigation handoff, index) live at
> `feedfilter/docs/on-device-llm/` — see the README there for what to
> read first depending on what you're doing.

This document captures the exact steps and gotchas to produce a locally-built
`CLiteRTLM.xcframework` that **actually works on an iPhone**, including all the
dead-ends discovered the hard way. Read this end-to-end before changing the
build setup — the project's CI build is not the same as a fresh local build,
and several environmental factors silently produce broken binaries.

The end goal: Bouncer iOS app loads the model, `CompiledModel::Create`
succeeds on iOS Metal, `getAuxiliaryOutput("logits")` returns the chat decode
logits, the bundled `linear_v3_head.bin` classifies them, and
`[Bench summary] AI-TEXT` lines appear in the device console.

---

## 1. Branch to build from

**Use `db450f38`** (or anything on `xcframework-classifier-only-decode` **before**
`899f6448`):

```bash
cd /Users/darrenjia/feedfilter/LiteRT-LM
git checkout db450f38
```

This commit has all of:
- Aux-output C API (`litert_lm_conversation_get_aux_output_floats`)
- `skipChatTemplate` field on `ConversationConfig`
- `PATCH.litert` (BIND-FIX — symmetric `custom_allocations_` cleanup; applied via `patches=` in WORKSPACE)
- `kv_cache_` GPU buffer storage fix (`dfedd5b8`, June 3 upstream)
- Classifier-only decode signature support

**Do NOT use `899f6448`** (the head of `xcframework-classifier-only-decode`).
It adds calls to `LiteRtCompiledModelT::MarkSignatureNeedsAllocationByKey()`
that don't exist in any LiteRT version — the build fails with
`no member named 'MarkSignatureNeedsAllocationByKey'`.

`backup-pre-upstream-merge-2026-06-03` (`7b49a44d`) is also missing the
`dfedd5b8` fix and the `PATCH.litert` — don't build from there for iOS.

---

## 2. **CRITICAL: the prebuilt accelerator dylibs**

Four `.dylib` files in `prebuilt/ios_arm64/` and `prebuilt/ios_sim_arm64/`
come from upstream `google-ai-edge/LiteRT-LM` via Git LFS. They are
**not built by our bazel** — they are opaque binary blobs Google publishes.

**Google has force-pushed newer versions of these blobs since the working
state was captured.** Pulling them from `main` today gives you binaries
that fail `CompiledModel::Create` with `status=504 kLiteRtStatusErrorCompilation`
("Some ops are not accelerated") on iOS Metal.

**You must pull the May 25 vintage**, from upstream commit `b41cb27`:

```bash
rm -rf /tmp/upstream-may
cd /tmp
git clone --filter=blob:none https://github.com/google-ai-edge/LiteRT-LM upstream-may
cd upstream-may
git checkout b41cb27
git lfs install
git lfs pull --include "prebuilt/ios_arm64/lib*.dylib,prebuilt/ios_sim_arm64/lib*.dylib"
cp prebuilt/ios_arm64/lib*.dylib    /Users/darrenjia/feedfilter/LiteRT-LM/prebuilt/ios_arm64/
cp prebuilt/ios_sim_arm64/lib*.dylib /Users/darrenjia/feedfilter/LiteRT-LM/prebuilt/ios_sim_arm64/
```

Known-good `libLiteRt.dylib` sha256:
`7798a6eb6f9abbfc000a99394eb060a7835edb9303b02e612bee2424a71a32ca`

If your `libLiteRt.dylib`'s sha differs, you have the wrong (newer)
upstream blob. Three of four dylibs (`libLiteRt`, `libLiteRtMetalAccelerator`,
`libLiteRtTopKMetalSampler`) differ between today's `main` and `b41cb27`;
only `libGemmaModelConstraintProvider` happens to be unchanged.

This is the single most important point in this document. The CI's
working `bench-timing-on-6186155` release was built against these older
blobs. Local builds with current upstream blobs will hit the Metal compile
failure regardless of every other variable.

---

## 3. Build `CLiteRTLM.xcframework` via bazel

```bash
cd /Users/darrenjia/feedfilter/LiteRT-LM
bazelisk build //swift:CLiteRTLM
```

Takes ~8-10 minutes from a cold cache (~30 seconds incremental).
Build output: `bazel-bin/swift/CLiteRTLM.xcframework.zip`.

**Toolchain requirements** (all already satisfied on the dev machine):
- Xcode 26.5 with the iPhoneOS 26.5 SDK
- `bazelisk` 1.29+ (auto-resolves Bazel 7.6.1 per `.bazelversion`)
- Rust 1.92+ (for the `tokenizers` crate)
- `git-lfs`

The `.bazelrc` settings are correct as-is; do not add custom `--config`
or `--define` flags for the iOS build.

If you've been doing macOS-side classify-binary builds, those use a
**different disk cache** (`~/.cache/bazel-mac-classify`) and a different
config. Don't share caches between iOS xcframework builds and macOS
builds.

---

## 4. Assemble `.local-xcframeworks/`

bazel only produces `CLiteRTLM.xcframework.zip`. The four accelerator
xcframeworks are wrapped from the prebuilt dylibs via `xcodebuild`:

```bash
cd /Users/darrenjia/feedfilter/LiteRT-LM
PREBUILT="$PWD/prebuilt"

# CLiteRTLM (from bazel)
rm -rf .local-xcframeworks/CLiteRTLM.xcframework
unzip -q bazel-bin/swift/CLiteRTLM.xcframework.zip -d .local-xcframeworks/

# Three accelerator dylibs that ship both device + simulator slices
for lib in libGemmaModelConstraintProvider libLiteRt libLiteRtMetalAccelerator; do
  rm -rf .local-xcframeworks/${lib}.xcframework
  xcodebuild -create-xcframework \
    -library "$PREBUILT/ios_arm64/${lib}.dylib" \
    -library "$PREBUILT/ios_sim_arm64/${lib}.dylib" \
    -output ".local-xcframeworks/${lib}.xcframework"
done

# libLiteRtTopKMetalSampler: device-only (no simulator slice upstream).
# The C++ side dlopens it conditionally on device; sim builds tolerate
# its absence.
rm -rf .local-xcframeworks/libLiteRtTopKMetalSampler.xcframework
xcodebuild -create-xcframework \
  -library "$PREBUILT/ios_arm64/libLiteRtTopKMetalSampler.dylib" \
  -output ".local-xcframeworks/libLiteRtTopKMetalSampler.xcframework"
```

After this, `.local-xcframeworks/` should contain five
`*.xcframework` directories — referenced as
`binaryTarget(name:path:)` from `Package.swift` on the
`xcframework-classifier-only-decode` line of branches.

---

## 5. Bouncer iOS project must point at the local package

`Bouncer_xcode/Bouncer.xcodeproj/project.pbxproj` should reference
the local LiteRT-LM repo via `XCLocalSwiftPackageReference`, NOT via
`XCRemoteSwiftPackageReference` to a fork release. The `experiment/upstream-gemma-on-bouncer-runtime`
branch has this wired up correctly. If you see
`XCRemoteSwiftPackageReference "LiteRT-LM"` in the pbxproj, swap it for:

```
4ED5E3A02FBD40000003BB9B /* XCLocalSwiftPackageReference "../LiteRT-LM" */ = {
    isa = XCLocalSwiftPackageReference;
    relativePath = ../LiteRT-LM;
};
```

(Three sites in the pbxproj: `packageReferences` list, the section block
above, and `XCSwiftPackageProductDependency.package`.)

The remote release URLs (`prefix-cache-v1`, `bench-timing-on-6186155`,
`xcframework-bouncer-v*`) do NOT expose `litert_lm_conversation_get_aux_output_floats`
or `litert_lm_conversation_config_set_skip_chat_template`. The classifier-head
flow requires both — a remote pin will compile but produce link errors or
silently miss the aux output.

---

## 6. Running on the device — DO NOT use Xcode's "Run"

If your iPhone is on **iOS 27** (or any beta where the lldb that ships
with Xcode 26 hasn't been updated), tapping the Xcode Run button attaches
lldb, which calls the private selector `-[OS_dispatch_mach_msg _setContext:]`
during queue inspection — iOS 27 removed that selector → instant crash on
launch with `unrecognized selector`.

This is unrelated to LiteRT-LM. The fix is to launch **without** the
debugger:

```bash
scripts/run-on-device.sh
```

That script does: build via `xcodebuild` → install via `devicectl` →
launch via `devicectl device process launch --console --terminate-existing`.
Stdout/stderr stream to the terminal (or `--tee <file>`). No lldb.

If you really need lldb: update Xcode to the matching beta for the iOS
version on the device.

---

## 7. Bouncer extension JS dependency

`Bouncer/` has a `file:./vendor/web-llm` dependency that must be installed.
After fresh checkout:

```bash
cd /Users/darrenjia/feedfilter/Bouncer
npm install
```

Otherwise the "Build Extension JS" build phase fails with
`ERROR: Could not resolve "@mlc-ai/web-llm"`.

---

## 8. Xcode user-script sandboxing

`xcodebuild` defaults to running Run Script build phases in a Seatbelt
sandbox that blocks Firebase Crashlytics' `run` script from reading
files under `DerivedData/SourcePackages/checkouts/firebase-ios-sdk/`.
`scripts/run-on-device.sh` already passes `ENABLE_USER_SCRIPT_SANDBOXING=NO`
to work around this. If you build via Xcode GUI, set
**target → Build Settings → User Script Sandboxing → No**.

---

## 9. Verifying the build worked

The benchmark mode auto-fires on engine-ready (gated by
`kBenchmarkOnlyMode` in `LocalInferenceService.swift`).
On a successful build + install + launch, the console emits:

```
[Head] loaded linear_v3 head v_dim=262144 n_class=4
[Bench chat start] samples=15
…
[Bench classify start] samples=12
[LogitFP] n=262144 v=262144 sum=... l2=... nan=0 top5=[(idx,val),…]   ← 36 of these total
…
[Bench summary] AI-TEXT (Swift linear_v3 head on chat logits) — logits = [p_human, p_partial, p_mostly, p_ai]
  [ XXXms] user_tweet_1     ai=0.86X logits=[…]  req="…"
  [ XXXms] user_tweet_2     ai=0.85X logits=[…]  req="…"
  [ XXXms] user_tweet_3     ai=0.29X logits=[…]  req="…"
  [ XXXms] user_tweet_4     ai=0.70X logits=[…]  req="…"
```

If you see `[CM-DBG-PrefillDecode] CompiledModel::Create FAILED — status=504`
in the log instead, the build environment is broken — most likely the
prebuilt accelerator dylibs (§2).

---

## 10. Common failure modes and their root causes

| Symptom | Root cause |
|---|---|
| `status=504 kLiteRtStatusErrorCompilation` "Some ops are not accelerated" | Newer-than-May-25 prebuilt accelerator dylibs (§2). |
| Build error: `no member named 'MarkSignatureNeedsAllocationByKey'` | On commit `899f6448`; check out `db450f38` instead. |
| iOS app crashes on launch with `_setContext: unrecognized selector` | Launched via Xcode Run on iOS 27 — use `scripts/run-on-device.sh`. |
| Build error: `Could not resolve "@mlc-ai/web-llm"` | `npm install` in `Bouncer/` not yet run (§7). |
| Build error: `Sandbox: bash deny(1) file-read-data .../Crashlytics/run` | User script sandboxing on (§8). |
| Engine creates but AI-text logits are `nan`/`inf` | The `compiled_model.cc` warn-not-fail patch (a debugging hack); revert it. Real fix is §2. |
| Cmd-B build error: `'engine.h' has been modified since the module file…` | Stale Clang PCM cache; `rm -rf DerivedData/Build/Intermediates.noindex ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex`. |
| App link fails: `Library not loaded: @rpath/libGemmaModelConstraintProvider.dylib` | `prebuilt/` was wiped or `.local-xcframeworks/` has empty subdirs; re-run §2 and §4. |

---

## 11. The CI vs local divergence (informational)

The fork's `build-ios-xcframework.yml` workflow builds the same source
on GitHub `macos-latest` runners. Its outputs (e.g.
`bench-timing-on-6186155`, `prefix-cache-v1`) use the May-25-vintage
prebuilts because the workflow was authored when those were what
`origin/main` of `google-ai-edge/LiteRT-LM` pointed at. The CI environment
itself doesn't have any magic; the difference between a working CI
binary and a non-working local binary at the same source commit is
*almost entirely the prebuilt blobs*. The `__text` section of CLiteRTLM
is byte-identical between local and CI builds at the same source — only
`__LINKEDIT` differs (code signature + metadata).

If we ever cut a new release that includes the aux-output API + skipChatTemplate,
it must be built against the May-25 prebuilts, otherwise downstream consumers
will hit the same Metal compile failure on iOS 27 devices.
