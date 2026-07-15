#!/bin/bash
# package_appstore_xcframeworks.sh — repackage LiteRT-LM iOS artifacts for App Store.
#
# WHY: App Store Connect rejects iOS apps that embed bare .dylib files in
# Bouncer.app/Frameworks/ (TN2435: only .framework bundles are allowed there).
# Uploads fail with ITMS-90426 "Invalid Swift Support: The SwiftSupport folder
# is missing" — a misleading message caused by the validator treating loose
# dylibs as Swift-support libraries. The four accelerator dylibs are opaque
# prebuilt blobs published by upstream google-ai-edge/LiteRT-LM (vintage-locked,
# see LOCAL_BUILD.md §2 — they must NOT be rebuilt from source), so this script
# transforms the existing known-good binaries without recompiling anything:
#
#   1. Wraps each bare dylib into a shallow iOS .framework bundle.
#   2. Renames per the map below. dlopen sites inside CLiteRTLM and libLiteRt
#      reference the accelerator/sampler by the literal string
#      "libLiteRt....dylib"; those C-string literals are patched IN PLACE to
#      "@rpath/<Name>.framework/<Name>". The new framework names are chosen so
#      the replacement is never longer than the original string:
#        libLiteRt                       -> LiteRt         (link-time only)
#        libGemmaModelConstraintProvider -> GemmaProvider  (link-time only)
#        libLiteRtMetalAccelerator       -> MtlAcc         (dlopen'd; 6-char cap)
#        libLiteRtTopKMetalSampler       -> TopKMS         (dlopen'd; 6-char cap)
#   3. Rewrites install names / load commands (install_name_tool) and adds an
#      @loader_path/.. rpath to the two binaries that dlopen plugins.
#   4. Generates dSYMs (fixes the "Upload Symbols Failed" ASC warnings; the
#      blobs are stripped so these carry symbol-table names only).
#   5. Re-creates the xcframeworks with -debug-symbols and zips them with
#      ditto (no ._* AppleDouble junk).
#
# Byte-identity note: the executable code (__text) of every binary is
# unchanged; only C-string literals, Mach-O load commands, and code signatures
# (re-signed ad hoc; Xcode re-signs on embed) are touched. LC_UUID is
# preserved, so the generated dSYMs match what ASC expects.
#
# Usage: package_appstore_xcframeworks.sh <dir-with-original-zips> <output-dir>
# Input zips: CLiteRTLM.xcframework.zip, libLiteRt.xcframework.zip,
#   libGemmaModelConstraintProvider.xcframework.zip,
#   libLiteRtMetalAccelerator.xcframework.zip,
#   libLiteRtTopKMetalSampler.xcframework.zip
set -euo pipefail

IN_DIR="${1:?usage: $0 <dir-with-original-zips> <output-dir>}"
OUT_DIR="${2:?usage: $0 <dir-with-original-zips> <output-dir>}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT_DIR"

# old-name -> new framework name (macOS bash 3.2: no associative arrays)
OLD_NAMES="libLiteRt libGemmaModelConstraintProvider libLiteRtMetalAccelerator libLiteRtTopKMetalSampler"
new_name() {
  case "$1" in
    libLiteRt) echo LiteRt ;;
    libGemmaModelConstraintProvider) echo GemmaProvider ;;
    libLiteRtMetalAccelerator) echo MtlAcc ;;
    libLiteRtTopKMetalSampler) echo TopKMS ;;
    *) echo "unknown dylib name: $1" >&2; return 1 ;;
  esac
}

# --- helpers ---------------------------------------------------------------

# patch_cstring <binary> <old> <new> <required: 0|1>
# In-place NUL-terminated C-string replacement; <new> must not be longer.
patch_cstring() {
  python3 - "$1" "$2" "$3" "$4" <<'EOF'
import sys
path, old, new, required = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode(), int(sys.argv[4])
assert len(new) <= len(old), f"replacement longer than original: {new}"
blob = open(path, "rb").read()
needle = old + b"\x00"
n = blob.count(needle)
if n == 0:
    if required:
        sys.exit(f"ERROR: '{old.decode()}' not found in {path}")
    print(f"  (skip: '{old.decode()}' not present in {path.split('/')[-1]})")
    sys.exit(0)
if n > 1:
    sys.exit(f"ERROR: '{old.decode()}' found {n} times in {path}; refusing to patch")
repl = new + b"\x00" * (len(old) - len(new) + 1)
open(path, "wb").write(blob.replace(needle, repl))
print(f"  patched '{old.decode()}' -> '{new.decode()}' in {path.split('/')[-1]}")
EOF
}

# normalize_minos <binary>
# ASC rejects (ITMS-90208) frameworks whose Mach-O minos exceeds the app's
# deployment target. GemmaProvider is built by our bazel without an explicit
# min-version flag, so it inherits the SDK default (e.g. 26.2) while the
# Google blobs are 15.0. Rewrite LC_BUILD_VERSION to minos 15.0, keeping the
# original platform and SDK version. No-op when already 15.0, so the Google
# blobs stay byte-identical. LC_UUID is not affected.
normalize_minos() {
  local bin="$1"
  local minos platform sdk
  minos=$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')
  [ "$minos" = "15.0" ] && return 0
  platform=$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f && /platform/{print $2; exit}')
  sdk=$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f && /sdk/{print $2; exit}')
  case "$platform" in
    2) platform=ios ;;
    7) platform=iossim ;;
    *) echo "ERROR: unexpected platform '$platform' in $bin" >&2; return 1 ;;
  esac
  vtool -set-build-version "$platform" 15.0 "$sdk" -replace -output "$bin" "$bin"
  echo "  normalized minos $minos -> 15.0 ($platform) in $(basename "$bin")"
}

# make_framework <slice-dir> <new-name> <dylib-path> <template-plist>
make_framework() {
  local slice_dir="$1" name="$2" dylib="$3" template="$4"
  local fw="$slice_dir/$name.framework"
  mkdir -p "$fw"
  cp "$dylib" "$fw/$name"
  chmod +x "$fw/$name"
  normalize_minos "$fw/$name"
  plutil -convert xml1 -o "$fw/Info.plist" "$template"
  plutil -replace CFBundleExecutable -string "$name" "$fw/Info.plist"
  plutil -replace CFBundleName -string "$name" "$fw/Info.plist"
  plutil -replace CFBundleIdentifier -string "com.google.odml.litert.$name" "$fw/Info.plist"
  plutil -convert binary1 "$fw/Info.plist"
  install_name_tool -id "@rpath/$name.framework/$name" "$fw/$name" 2>/dev/null
}

# finalize <binary>: dSYM next to the framework, then ad-hoc re-sign.
finalize() {
  local bin="$1"
  dsymutil "$bin" -o "$(dirname "$(dirname "$bin")")/$(basename "$bin").framework.dSYM" >/dev/null 2>&1
  codesign --force --sign - "$(dirname "$bin")" >/dev/null 2>&1
}

# --- unpack ----------------------------------------------------------------

echo "== Unpacking originals"
for z in "$IN_DIR"/*.xcframework.zip; do
  unzip -q "$z" -d "$WORK/orig"
done
find "$WORK/orig" -name "._*" -delete   # AppleDouble junk from old zips

# Per-slice Info.plist templates from CLiteRTLM (known to pass ASC validation).
TPL_DEV="$WORK/orig/CLiteRTLM.xcframework/ios-arm64/CLiteRTLM.framework/Info.plist"
TPL_SIM="$WORK/orig/CLiteRTLM.xcframework/ios-arm64-simulator/CLiteRTLM.framework/Info.plist"

# --- wrap the four dylibs ---------------------------------------------------

echo "== Wrapping dylibs into frameworks"
for old in $OLD_NAMES; do
  new="$(new_name "$old")"
  for slice in ios-arm64 ios-arm64-simulator; do
    dylib="$WORK/orig/$old.xcframework/$slice/$old.dylib"
    [ -f "$dylib" ] || continue   # sampler has no simulator slice
    tpl="$TPL_DEV"; [ "$slice" = "ios-arm64-simulator" ] && tpl="$TPL_SIM"
    mkdir -p "$WORK/build/$slice"
    make_framework "$WORK/build/$slice" "$new" "$dylib" "$tpl"
    echo "  $old.dylib -> $slice/$new.framework"
  done
done

# libLiteRt dlopens the Metal accelerator by name; patch + rpath, all slices.
for slice in ios-arm64 ios-arm64-simulator; do
  bin="$WORK/build/$slice/LiteRt.framework/LiteRt"
  [ -f "$bin" ] || continue
  patch_cstring "$bin" "libLiteRtMetalAccelerator.dylib" "@rpath/MtlAcc.framework/MtlAcc" 1
  install_name_tool -add_rpath "@loader_path/.." "$bin" 2>/dev/null || true
done

# --- CLiteRTLM: dlopen strings + Gemma load command --------------------------

echo "== Patching CLiteRTLM"
for slice in ios-arm64 ios-arm64-simulator; do
  fw="$WORK/orig/CLiteRTLM.xcframework/$slice/CLiteRTLM.framework"
  [ -d "$fw" ] || continue
  bin="$fw/CLiteRTLM"
  patch_cstring "$bin" "libLiteRtMetalAccelerator.dylib" "@rpath/MtlAcc.framework/MtlAcc" 1
  patch_cstring "$bin" "libLiteRtTopKMetalSampler.dylib" "@rpath/TopKMS.framework/TopKMS" 1
  install_name_tool -change \
    "@rpath/libGemmaModelConstraintProvider.dylib" \
    "@rpath/GemmaProvider.framework/GemmaProvider" "$bin" 2>/dev/null
  install_name_tool -add_rpath "@loader_path/.." "$bin" 2>/dev/null || true
  mkdir -p "$WORK/build/$slice"
  cp -R "$fw" "$WORK/build/$slice/"
done

# --- dSYMs, signing, xcframeworks, zips --------------------------------------

echo "== Generating dSYMs, signing, creating xcframeworks"
for fw in "$WORK"/build/*/*.framework; do
  finalize "$fw/$(basename "$fw" .framework)"
done

for name in CLiteRTLM LiteRt GemmaProvider MtlAcc TopKMS; do
  args=()
  for slice in ios-arm64 ios-arm64-simulator; do
    fw="$WORK/build/$slice/$name.framework"
    [ -d "$fw" ] || continue
    args+=(-framework "$fw" -debug-symbols "$WORK/build/$slice/$name.framework.dSYM")
  done
  rm -rf "$OUT_DIR/$name.xcframework" "$OUT_DIR/$name.xcframework.zip"
  xcodebuild -create-xcframework "${args[@]}" -output "$OUT_DIR/$name.xcframework" >/dev/null
  (cd "$OUT_DIR" && ditto -c -k --keepParent "$name.xcframework" "$name.xcframework.zip")
  echo "  $name.xcframework.zip"
done

echo "== Checksums (for Package.swift)"
for name in CLiteRTLM LiteRt GemmaProvider MtlAcc TopKMS; do
  echo "  $name: $(swift package compute-checksum "$OUT_DIR/$name.xcframework.zip")"
done
echo "Done."
