#!/bin/bash
# Builds and packages litertlm-android.aar for arm64-v8a from this repo.
#
# The AAR contains:
#   - classes.jar: the Kotlin API (com.google.ai.edge.litertlm)
#   - jni/arm64-v8a/liblitertlm_jni.so (stripped)
#   - jni/arm64-v8a/*.so runtime companions: libGemmaModelConstraintProvider.so
#     is a DT_NEEDED dependency of the JNI lib; the LiteRT accelerator libs
#     (GPU/OpenCL/WebGPU/samplers) are dlopen()ed at runtime for GPU inference.
#     All come from //prebuilt/android_arm64.
#
# Prereqs: bazel, ANDROID_NDK_HOME (r28b), ANDROID_HOME with an integer-named
# platforms/android-NN (bazel's android_sdk_repository cannot parse dotted
# platform dirs like android-36.1).
#
# Usage: tools/package_android_aar.sh [output.aar]

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-$PWD/litertlm-android.aar}"
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME (e.g. .../ndk/android-ndk-r28b)}"
: "${ANDROID_HOME:?set ANDROID_HOME (e.g. ~/Library/Android/sdk)}"

echo "== bazel build (android_arm64)"
bazel build --config=android_arm64 \
  //kotlin/java/com/google/ai/edge/litertlm/jni:litertlm_jni \
  //kotlin/java/com/google/ai/edge/litertlm:litertlm-android_kt

BIN=bazel-out/arm64-v8a-opt/bin
STRIP="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip"
[ -x "$STRIP" ] || STRIP="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "== staging AAR"
mkdir -p "$STAGE/jni/arm64-v8a"
cp "$BIN/kotlin/java/com/google/ai/edge/litertlm/litertlm-android_kt.jar" "$STAGE/classes.jar"
cp "$BIN/kotlin/java/com/google/ai/edge/litertlm/jni/liblitertlm_jni.so" "$STAGE/jni/arm64-v8a/"
chmod +w "$STAGE/jni/arm64-v8a/liblitertlm_jni.so"
"$STRIP" --strip-debug "$STAGE/jni/arm64-v8a/liblitertlm_jni.so"
cp prebuilt/android_arm64/*.so "$STAGE/jni/arm64-v8a/"

cat > "$STAGE/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.google.ai.edge.litertlm">
    <uses-sdk android:minSdkVersion="23" />
</manifest>
EOF
touch "$STAGE/R.txt"

rm -f "$OUT"
(cd "$STAGE" && zip -q -r "$OUT" AndroidManifest.xml classes.jar R.txt jni)

echo "== done"
ls -la "$OUT"
shasum -a 256 "$OUT"
