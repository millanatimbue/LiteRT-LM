# Local iteration loop (skip CI)

Bouncer's iOS xcodeproj is wired to consume this fork **as a local SPM
package** when developing locally. Edits to runtime sources → bazel rebuild →
drop xcframework → Cmd+R in Xcode. No commit, push, tag, release, or
checksum bump.

## One-time setup (already done)

1. iOS prebuilt dylibs fetched from upstream LFS into `prebuilt/ios_arm64/`
   and `prebuilt/ios_sim_arm64/`. These are deterministic from upstream — only
   re-fetch if upstream bumps them.
2. `.local-xcframeworks/` populated with:
   - `CLiteRTLM.xcframework` (rebuilt below)
   - `libGemmaModelConstraintProvider.xcframework` (copied from DerivedData)
   - `libLiteRt.xcframework` (copied from DerivedData)
   - `libLiteRtMetalAccelerator.xcframework` (copied from DerivedData)
   - `libLiteRtTopKMetalSampler.xcframework` (copied from DerivedData)
3. `Package.swift` switched to `binaryTarget(name:path:)` referencing
   `.local-xcframeworks/*.xcframework`. Original remote-URL version is in
   `Package.swift.remote-bak`.
4. `Bouncer_xcode/Bouncer.xcodeproj/project.pbxproj` switched from
   `XCRemoteSwiftPackageReference` (revision-pinned to a fork commit) to
   `XCLocalSwiftPackageReference` with `relativePath = ../LiteRT-LM`.

## Per-iteration loop

After editing any C++ source under `runtime/...`:

```bash
cd /Users/darrenjia/feedfilter/LiteRT-LM
bazelisk build --disk_cache=$HOME/.cache/bazel-ios-local //swift:CLiteRTLM
rm -rf .local-xcframeworks/CLiteRTLM.xcframework
ditto -x -k bazel-bin/swift/CLiteRTLM.xcframework.zip .local-xcframeworks/
```

Then Cmd+R in Xcode (or `xcodebuild -project Bouncer.xcodeproj -scheme
"Bouncer (iOS)" -destination 'platform=iOS Simulator,id=…' build`).

For Swift-only edits in `swift/*.swift`, skip the bazel rebuild — Xcode
compiles the swift files directly and a Cmd+R is enough (~15–30s).

## Restoring CI mode (when ready to ship)

When the fix is verified and you want to push for an XCFramework release:

```bash
# 1. Push runtime changes
git checkout expose-aux-tensor-outputs   # or branch
# (your changes to runtime/components/...)
git add runtime/ ...
git commit -m "..."
git push origin expose-aux-tensor-outputs

# 2. Restore remote-URL Package.swift for downstream consumers
cp Package.swift.remote-bak Package.swift   # then update v# tag/checksums
                                              # after CI release publishes

# 3. Bouncer_xcode: restore remote package reference
#    Edit Bouncer.xcodeproj/project.pbxproj — swap the XCLocalSwiftPackageReference
#    block back to the XCRemoteSwiftPackageReference block with the new revision.
```

The `Package.swift.remote-bak` snapshot is the v4 URLs/checksums; update the
URLs to the new tag and the checksums to the new release zips before
committing.

## Why this works

SPM resolves package references in the project; a local package is loaded
straight from disk (no checkout, no checksum check, no download). The local
`Package.swift` uses `binaryTarget(name:path:)` which references xcframeworks
already on disk — same form the binary distributions use, just from a local
path. The Swift wrapper target (`LiteRTLM`) and the executable consuming
this package don't know or care whether the binaries arrived via release zip
or local file path.
