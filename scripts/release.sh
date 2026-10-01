#!/bin/sh
# Builds a release into dist/:
#   LegacyDisplay-<version>.deb, SHA256SUMS and release-notes.md for GitHub Releases
#   repo/  a flat APT repository (a "source" in Sileo, Zebra and Cydia) for GitHub Pages
#
# The project's URLs come from the "origin" remote; override them with
# REPO_URL (the GitHub page) and SITE_URL (where repo/ is served).
set -eu
cd "$(dirname "$0")/.."

die() {
    echo "release: $*" >&2
    exit 1
}

version=$(sed -n 's/^Version: //p' control)
plist_version=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
[ "$version" = "$plist_version" ] || die "control says $version but Info.plist says $plist_version"
if [ "${GITHUB_REF_TYPE:-}" = tag ] && [ "${GITHUB_REF_NAME:-}" != "v$version" ]; then
    die "tag ${GITHUB_REF_NAME:-} doesn't match version $version (expected v$version)"
fi

if [ -z "${REPO_URL:-}" ]; then
    origin=$(git remote get-url origin 2>/dev/null) || die "no origin remote; set REPO_URL and SITE_URL"
    slug=$(printf '%s\n' "$origin" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')
    REPO_URL="https://github.com/$slug"
fi
if [ -z "${SITE_URL:-}" ]; then
    slug=${REPO_URL#https://github.com/}
    owner=$(printf '%s' "${slug%%/*}" | tr '[:upper:]' '[:lower:]')
    SITE_URL="https://$owner.github.io/${slug#*/}/"
fi

rm -rf dist packages
make package FINALPACKAGE=1
mkdir -p dist/repo/debs
name="LegacyDisplay-$version.deb"
cp packages/*.deb "dist/$name"
cp "dist/$name" "dist/repo/debs/$name"
(cd dist && shasum -a 256 "$name" > SHA256SUMS)

# Packages: the deb's own control stanza plus where to fetch it and its hashes.
deb="dist/repo/debs/$name"
control_member=$(ar t "$deb" | grep '^control\.tar')
{
    ar p "$deb" "$control_member" | tar -xOf - ./control | sed '/^$/d'
    echo "Filename: debs/$name"
    echo "Size: $(wc -c < "$deb" | tr -d ' ')"
    echo "MD5sum: $(md5 -q "$deb")"
    echo "SHA1: $(shasum -a 1 "$deb" | cut -d' ' -f1)"
    echo "SHA256: $(shasum -a 256 "$deb" | cut -d' ' -f1)"
    echo "Homepage: $REPO_URL"
    echo "Depiction: $REPO_URL#readme"
    echo "Icon: ${SITE_URL}icon.png"
    echo
} > dist/repo/Packages
gzip -9nkf dist/repo/Packages
bzip2 -9kf dist/repo/Packages

{
    echo "Origin: LegacyDisplay"
    echo "Label: LegacyDisplay"
    echo "Suite: stable"
    echo "Version: $version"
    echo "Codename: ios"
    echo "Date: $(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S UTC')"
    echo "Architectures: iphoneos-arm"
    echo "Components: main"
    echo "Description: Use an old jailbroken iPad as a second display for your Mac"
    for algorithm in MD5Sum SHA256; do
        echo "$algorithm:"
        for index in Packages Packages.gz Packages.bz2; do
            file="dist/repo/$index"
            if [ "$algorithm" = MD5Sum ]; then hash=$(md5 -q "$file"); else hash=$(shasum -a 256 "$file" | cut -d' ' -f1); fi
            echo " $hash $(wc -c < "$file" | tr -d ' ') $index"
        done
    done
} > dist/repo/Release

cp Resources/AppIcon76x76@2x~ipad.png dist/repo/icon.png
cp Resources/AppIcon76x76@2x~ipad.png dist/repo/CydiaIcon.png
sed -e "s#{{SITE_URL}}#$SITE_URL#g" -e "s#{{REPO_URL}}#$REPO_URL#g" \
    -e "s#{{VERSION}}#$version#g" -e "s#{{DEB}}#debs/$name#g" site/index.html > dist/repo/index.html

cat > dist/release-notes.md <<EOF
Use an old jailbroken iPad as a second display for your Mac, over USB or Wi-Fi.

### Install

1. **On your Mac**, install [OpenDisplay](https://github.com/peetzweg/opendisplay/releases/latest)
   (download \`OpenDisplay.dmg\` and drag the app into Applications). Open it, allow
   **Screen Recording** and **Accessibility** when asked, then quit it (⌘Q) and open it again.
2. **On your iPad**, add this source in Sileo, Zebra or Cydia and install **LegacyDisplay**:
   \`$SITE_URL\`
   Or open [$SITE_URL]($SITE_URL) in Safari on the iPad and tap your package manager's button.
   Or download \`$name\` below and open it in Filza.
3. **Open LegacyDisplay** on the iPad, then plug in the cable or join the same Wi-Fi as the Mac.

Needs a 64-bit iPad or iPhone (A7 or newer) with a rootful jailbreak on iOS 12 or later.
On iPadOS 15 and later, use OpenDisplay's official app instead.

SHA-256 of \`$name\`: \`$(cut -d' ' -f1 dist/SHA256SUMS)\`
EOF

echo "Built dist/$name and dist/repo/ for $SITE_URL"
