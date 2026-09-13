#!/bin/sh
# Packages a built Whiskr.app as the download a release carries: a zip made with ditto (which keeps the
# bundle's symbolic links, permissions and extended attributes) and its SHA-256 checksum.
#
#   Scripts/package.sh <path/to/Whiskr.app> <output folder>
#
# The app is not signed or notarised; it keeps only the ad-hoc signature the linker gives it. See
# docs/RELEASING.md for what that means for people who download it.
set -eu

app=${1:?usage: package.sh <Whiskr.app> <output folder>}
out=${2:?usage: package.sh <Whiskr.app> <output folder>}

[ -d "$app" ] || { echo "package.sh: no app at $app" >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
archs=$(lipo -archs "$app/Contents/MacOS/Whiskr")
case "$archs" in *x86_64*arm64*|*arm64*x86_64*) archs=universal ;; esac
name="Whiskr-$version-macOS-$archs-unsigned.zip"

# The bundle itself is not sealed (code signing is off in the project); each executable carries the
# ad-hoc signature the linker gives it, which Apple silicon needs to run it. Check that each one does.
for executable in "$app"/Contents/MacOS/*; do
    case $(basename "$executable") in *.dylib) continue ;; esac
    codesign -dv "$executable" 2>&1 | grep -q 'flags=.*linker-signed' || { echo "package.sh: $executable is not linker-signed" >&2; exit 1; }
done

mkdir -p "$out"
rm -f "$out/$name" "$out/$name.sha256"
ditto -c -k --keepParent --sequesterRsrc "$app" "$out/$name"
(cd "$out" && shasum -a 256 "$name" > "$name.sha256")

echo "Packaged: $out/$name"
cat "$out/$name.sha256"
