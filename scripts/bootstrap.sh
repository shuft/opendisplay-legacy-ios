#!/bin/sh
# Fetches the build toolchain into .local/ (git-ignored), so nothing is
# installed system-wide: theos, the iPhoneOS 14.5 SDK and ldid. Only the
# macOS Command Line Tools (xcode-select --install) are needed beforehand.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .local/bin
cd .local

if [ ! -d theos ]; then
    git clone --recursive --depth 1 --shallow-submodules https://github.com/theos/theos.git theos
fi

if [ ! -d theos/sdks/iPhoneOS14.5.sdk ]; then
    rm -rf sdks-checkout
    git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git sdks-checkout
    git -C sdks-checkout sparse-checkout set iPhoneOS14.5.sdk
    mv sdks-checkout/iPhoneOS14.5.sdk theos/sdks/
    rm -rf sdks-checkout
fi

if [ ! -x bin/ldid ]; then
    case "$(uname -m)" in
        arm64) arch=arm64 ;;
        *) arch=x86_64 ;;
    esac
    curl -fsSL -o bin/ldid "https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_macosx_$arch"
    chmod +x bin/ldid
fi

echo "Toolchain ready in $(pwd). Build with: make package"
