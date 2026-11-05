#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
[[ $(uname -s) == Darwin ]] || { echo 'This script requires macOS.' >&2; exit 1; }
command -v brew >/dev/null || { echo 'Install Homebrew first: https://brew.sh' >&2; exit 1; }
xcrun --find clang >/dev/null

export HOMEBREW_NO_AUTO_UPDATE=1
missing=()
for package in cmake ninja boost qtbase qttools qtwebengine qtsvg qtimageformats jpeg libtiff; do
    brew list --versions "$package" >/dev/null 2>&1 || missing+=("$package")
done
if (( ${#missing[@]} )); then
    brew install "${missing[@]}"
fi

brew_prefix=$(brew --prefix)
build_dir="$PWD/build"
mkdir -p "$build_dir"

# The repository's Eigen copy is incomplete; use the verified upstream release.
if [[ ! -f "$build_dir/eigen-3.4.0/Eigen/src/Core/util/Macros.h" ]]; then
    curl -fL --retry 3 https://gitlab.com/libeigen/eigen/-/archive/3.4.0/eigen-3.4.0.tar.gz \
        -o "$build_dir/eigen-3.4.0.tar.gz"
    echo "8586084f71f9bde545ee7fa6d00288b264a2b7ac3607b974e54d13e7162c1c72  $build_dir/eigen-3.4.0.tar.gz" \
        | shasum -a 256 -c -
    tar -xzf "$build_dir/eigen-3.4.0.tar.gz" -C "$build_dir"
fi

arch=X86
[[ $(uname -m) != arm64 ]] || arch=ARM
"$brew_prefix/bin/cmake" -S . -B "$build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MAKE_PROGRAM="$brew_prefix/bin/ninja" \
    -DCMAKE_PREFIX_PATH="$brew_prefix" \
    -DST_ARCH="$arch" -DST_USE_QT6=ON \
    -DEIGEN3_INCLUDE_DIR="$build_dir/eigen-3.4.0" \
    -DENABLE_PDF_INPUT=ON -DENABLE_PDF_EXPORT=ON \
    -DENABLE_OPENCL=OFF
"$brew_prefix/bin/cmake" --build "$build_dir" --parallel "$(sysctl -n hw.ncpu)"
"$brew_prefix/bin/cmake" --install "$build_dir" --prefix "$build_dir/macos"

app="$build_dir/macos/scantailor-experimental.app"
# CMake preserves Homebrew plugin symlinks, which point outside the app bundle.
while IFS= read -r link; do
    relative="${link#"$app/Contents/PlugIns/"}"
    cp -L "$brew_prefix/share/qt/plugins/$relative" "$link.copy"
    mv -f "$link.copy" "$link"
done < <(find "$app/Contents/PlugIns" -type l)

"$(brew --prefix qtbase)/bin/macdeployqt" "$app" \
    -executable="$app/Contents/Library/scantailor-experimental-cli" \
    -always-overwrite -no-codesign
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/scantailor-experimental" --help >/dev/null
"$app/Contents/Library/scantailor-experimental-cli" --help >/dev/null

hdiutil create -ov -volname 'ScanTailor PDF+' -srcfolder "$build_dir/macos" \
    -format UDZO "$build_dir/scantailor-pdf-plus-macos-$(uname -m).dmg"
printf '\nApp: %s\nDMG: %s\n' "$app" "$build_dir/scantailor-pdf-plus-macos-$(uname -m).dmg"
echo 'Ad-hoc signed, not notarized. OpenCL disabled. Run ctest --test-dir build --output-on-failure to check tests.'
