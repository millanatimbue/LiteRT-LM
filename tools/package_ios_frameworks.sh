#!/bin/bash
# Package the iOS binaries as framework-wrapped xcframeworks for SPM.
#
# The App Store rejects bare .dylib files in an app bundle (surfaces as the
# misleading ITMS-90426 "SwiftSupport folder is missing"), so every prebuilt
# accelerator dylib must ship inside a .framework bundle. This script:
#
#   1. Wraps each prebuilt dylib in a shallow iOS framework bundle with a
#      framework-style install name (@rpath/X.framework/X).
#   2. Patches the hardcoded dlopen name inside the opaque libLiteRt blob
#      ("libLiteRtMetalAccelerator.dylib" -> "libLiteRtMetalAccelerator",
#      NUL-padded in place) and adds an LC_RPATH so dyld's leaf-name @rpath
#      expansion finds the framework binary.
#   3. Rewrites CLiteRTLM's load command for libGemmaModelConstraintProvider
#      to the framework install name (bazel links against the bare dylib).
#   4. Assembles .local-xcframeworks/ and SPM-ready zips + checksums in
#      dist-xcframeworks/.
#
# Prereq: bazelisk build //swift:CLiteRTLM  (produces bazel-bin/swift/CLiteRTLM.xcframework.zip)
set -euo pipefail
cd "$(dirname "$0")/.."

PREBUILT="$PWD/prebuilt"
OUT="$PWD/.local-xcframeworks"
DIST="$PWD/dist-xcframeworks"
STAGE="$(mktemp -d /tmp/litert-fw-stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

GEMMA_OLD="@rpath/libGemmaModelConstraintProvider.dylib"
GEMMA_NEW="@rpath/libGemmaModelConstraintProvider.framework/libGemmaModelConstraintProvider"

binary_minos() {
  otool -l "$1" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}'
}

write_info_plist() { # $1=dir $2=name $3=platform $4=minos
  cat > "$1/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$2</string>
	<key>CFBundleIdentifier</key>
	<string>com.litertlm.$2</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$2</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>$3</string>
	</array>
	<key>MinimumOSVersion</key>
	<string>$4</string>
</dict>
</plist>
EOF
}

patch_liblitert_dlopen_name() { # $1=binary
  python3 - "$1" <<'PYEOF'
import sys
path = sys.argv[1]
old = b"libLiteRtMetalAccelerator.dylib\x00"
new = b"libLiteRtMetalAccelerator" + b"\x00" * (len(old) - len(b"libLiteRtMetalAccelerator"))
assert len(old) == len(new)
data = open(path, "rb").read()
n = data.count(old)
assert n == 1, f"expected exactly 1 occurrence of dlopen name, found {n}"
open(path, "wb").write(data.replace(old, new))
print(f"  patched dlopen name in {path}")
PYEOF
}

make_framework() { # $1=lib name $2=src dylib $3=platform $4=outdir
  local name="$1" src="$2" platform="$3" outdir="$4"
  local fw="$outdir/$name.framework"
  rm -rf "$fw"
  mkdir -p "$fw"
  cp "$src" "$fw/$name"
  chmod +w "$fw/$name"
  if [ "$name" = "libLiteRt" ]; then
    patch_liblitert_dlopen_name "$fw/$name"
    # libLiteRt dlopens the Metal accelerator by leaf name; give the leaf-name
    # @rpath expansion a path that lands inside the sibling framework. The two
    # stale rpaths only served the old bare-dylib leaf lookup — dropping them
    # frees exactly the load-command bytes the sim slice needs for the new
    # rpath + longer install name (the blob was linked without headerpad).
    install_name_tool -delete_rpath "@executable_path/Frameworks" "$fw/$name"
    install_name_tool -delete_rpath "@loader_path/Frameworks" "$fw/$name"
    install_name_tool -add_rpath "@loader_path/../libLiteRtMetalAccelerator.framework" "$fw/$name"
  fi
  install_name_tool -id "@rpath/$name.framework/$name" "$fw/$name"
  write_info_plist "$fw" "$name" "$platform" "$(binary_minos "$fw/$name")"
  codesign --force --sign - "$fw" >/dev/null 2>&1
  echo "$fw"
}

echo "== Staging framework slices"
DEVICE_LIBS=(libGemmaModelConstraintProvider libLiteRt libLiteRtMetalAccelerator libLiteRtTopKMetalSampler)
SIM_LIBS=(libGemmaModelConstraintProvider libLiteRt libLiteRtMetalAccelerator)

mkdir -p "$STAGE/device" "$STAGE/sim"
for lib in "${DEVICE_LIBS[@]}"; do
  make_framework "$lib" "$PREBUILT/ios_arm64/$lib.dylib" iPhoneOS "$STAGE/device"
done
for lib in "${SIM_LIBS[@]}"; do
  make_framework "$lib" "$PREBUILT/ios_sim_arm64/$lib.dylib" iPhoneSimulator "$STAGE/sim"
done

echo "== Repackaging CLiteRTLM with framework-style Gemma load command"
unzip -q -o bazel-bin/swift/CLiteRTLM.xcframework.zip -d "$STAGE"
for slice_bin in "$STAGE"/CLiteRTLM.xcframework/*/CLiteRTLM.framework/CLiteRTLM; do
  chmod +w "$slice_bin"
  install_name_tool -change "$GEMMA_OLD" "$GEMMA_NEW" "$slice_bin"
  codesign --force --sign - "$(dirname "$slice_bin")" >/dev/null 2>&1
done

echo "== Creating xcframeworks"
mkdir -p "$OUT" "$DIST"
rm -rf "$OUT/CLiteRTLM.xcframework"
mv "$STAGE/CLiteRTLM.xcframework" "$OUT/"

for lib in "${SIM_LIBS[@]}"; do
  rm -rf "$OUT/$lib.xcframework"
  xcodebuild -create-xcframework \
    -framework "$STAGE/device/$lib.framework" \
    -framework "$STAGE/sim/$lib.framework" \
    -output "$OUT/$lib.xcframework"
done
# TopK Metal sampler has no simulator slice upstream; sim builds tolerate its
# absence (dlopen falls back to the statically linked / CPU path).
rm -rf "$OUT/libLiteRtTopKMetalSampler.xcframework"
xcodebuild -create-xcframework \
  -framework "$STAGE/device/libLiteRtTopKMetalSampler.framework" \
  -output "$OUT/libLiteRtTopKMetalSampler.xcframework"

echo "== Zipping for SPM + checksums"
rm -f "$DIST"/*.xcframework.zip
for xcf in "$OUT"/*.xcframework; do
  name="$(basename "$xcf")"
  (cd "$OUT" && ditto -c -k --keepParent "$name" "$DIST/$name.zip")
done
for zip in "$DIST"/*.zip; do
  echo "$(basename "$zip"): $(swift package compute-checksum "$zip")"
done

echo "== Done. xcframeworks in $OUT, release zips in $DIST"
