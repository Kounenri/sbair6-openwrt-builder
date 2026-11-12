#!/bin/bash
# Publishes one build's packages as an apk repository, in the layout the image's distfeeds.list expects:
#   targets/<board>/<subtarget>/packages/packages.adb
#   targets/<board>/<subtarget>/kmods/<version>-<release>-<vermagic>/packages.adb
#   packages/<arch>/<feed>/packages.adb
#   keys/public-key.pem
# Usage: scripts/publish-feed.sh STAMP DEST
#   STAMP  build ID printed by ./build.sh start (out/STAMP/ must have been collected)
#   DEST   a local directory, or [user@]host:/path (rsync over ssh; no spaces in the path)
#   --flat write the tree at DEST itself instead of DEST/STAMP (no build ID in the URL, no latest symlink)
# The tree is written to DEST/STAMP and DEST/latest is a symlink to it. The packages of a build are signed with that
# build's key, and the image of the same build trusts it, so do not mix builds in one directory.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
K=$(cd "$HERE/.." && pwd)
STAMP=${1:?usage: scripts/publish-feed.sh STAMP DEST [--flat]}
DEST=${2:?usage: scripts/publish-feed.sh STAMP DEST [--flat]}
FLAT=
shift 2
while [ $# -gt 0 ]; do
	case "$1" in
	--flat) FLAT=1 ;;
	*) echo "usage: scripts/publish-feed.sh STAMP DEST [--flat]" >&2; exit 2 ;;
	esac
	shift
done
OUT=$K/out/$STAMP
[ -d "$OUT/packages" ] || { echo "no $OUT/packages: build and collect $STAMP first" >&2; exit 1; }
if [ -f "$OUT/repo-layout" ]; then
	target=$(sed -n '1p' "$OUT/repo-layout")   # targets/mediatek/mt6990/packages
	kmods=$(sed -n '2p' "$OUT/repo-layout")    # targets/mediatek/mt6990/kmods/... (empty on old builds)
	pkgdir=$(sed -n '3p' "$OUT/repo-layout")   # packages/aarch64_cortex-a55_neon-vfpv4
else
	# A build from before repo-layout: this kit has one board, and the arch is the name under packages/feeds.
	arch=$(find "$OUT/packages/feeds" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n 1)
	[ -n "$arch" ] || { echo "$OUT/packages/feeds is empty" >&2; exit 1; }
	target=targets/mediatek/mt6990/packages
	kmods=
	pkgdir=packages/$arch
	echo "note: no $OUT/repo-layout; assuming $target and $pkgdir" >&2
fi
# Two-line repo-layout predates the kmods split.
if [ -z "$pkgdir" ]; then
	pkgdir=$kmods
	kmods=
fi
arch=${pkgdir##*/}
[ -n "$target" ] && [ -n "$arch" ] || { echo "bad repository layout" >&2; exit 1; }
command -v rsync > /dev/null || { echo "rsync is not installed" >&2; exit 1; }
# A modem build carries the stock vendor modem userspace in its air6 feed, which may not be redistributed.
if [ -f "$OUT/PROVENANCE" ] && grep -q '^modem: AIR6_MODEM=' "$OUT/PROVENANCE" && [ "${AIR6_PUBLISH_MODEM:-}" != 1 ]; then
	echo "refusing: $STAMP is a modem build; its packages carry stock vendor userspace" >&2
	echo "rebuild without AIR6_MODEM to publish it (AIR6_PUBLISH_MODEM=1 overrides)" >&2
	exit 1
fi

TMP=$(mktemp -d) && trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/$target" "$TMP/$pkgdir" "$TMP/keys"
cp -a "$OUT/packages/target/." "$TMP/$target/"
if [ -n "$kmods" ] && [ -d "$OUT/packages/kmods/$(basename "$kmods")" ]; then
	mkdir -p "$TMP/$kmods"
	cp -a "$OUT/packages/kmods/$(basename "$kmods")/." "$TMP/$kmods/"
fi
if [ -d "$OUT/packages/feeds/$arch" ]; then
	cp -a "$OUT/packages/feeds/$arch/." "$TMP/$pkgdir/"
fi
[ ! -f "$OUT/keys/public-key.pem" ] || cp "$OUT/keys/public-key.pem" "$TMP/keys/"

[ -f "$TMP/$target/packages.adb" ] || { echo "no packages.adb in $target" >&2; exit 1; }
[ -z "$kmods" ] || [ -f "$TMP/$kmods/packages.adb" ] || { echo "no packages.adb in $kmods" >&2; exit 1; }
# A feed that built no package has no index; it cannot be served. The image of a build without --all-packages still
# lists such feeds in distfeeds.list, and apk reports them as unavailable (it uses the others).
empty=
for d in "$TMP/$pkgdir"/*; do
	[ -d "$d" ] || continue
	[ -f "$d/packages.adb" ] && continue
	empty="$empty ${d#$TMP/}"
	rm -rf "$d"
done
[ -z "$empty" ] || echo "warning: no packages.adb, left out:$empty" >&2
n=$(find "$TMP" -name '*.apk' | wc -l)
[ "$n" -gt 0 ] || { echo "no .apk in $OUT/packages" >&2; exit 1; }

if [ -n "$FLAT" ]; then
	# The build ID is not part of the path: a later build replaces this tree. Devices that keep the URL then see the
	# newer packages (and the newer signing key), so keep that in mind before publishing another build.
	case "$DEST" in
	*:*)
		host=${DEST%%:*}
		path=${DEST#*:}
		ssh "$host" "mkdir -p '$path'"
		rsync -a --chmod=D755,F644 --delete "$TMP/" "$host:$path/"
		ssh "$host" "chmod 755 '$path'"
		;;
	*)
		mkdir -p "$DEST"
		rsync -a --chmod=D755,F644 --delete "$TMP/" "$DEST/"
		chmod 755 "$DEST"
		;;
	esac
	echo "published $n packages to $DEST (flat, no build ID in the path)"
else
	case "$DEST" in
	*:*)
		host=${DEST%%:*}
		path=${DEST#*:}
		ssh "$host" "mkdir -p '$path'"
		rsync -a --chmod=D755,F644 --delete "$TMP/" "$host:$path/$STAMP/"
		ssh "$host" "ln -sfn '$STAMP' '$path/latest'"
		;;
	*)
		mkdir -p "$DEST"
		rsync -a --chmod=D755,F644 --delete "$TMP/" "$DEST/$STAMP/"
		ln -sfn "$STAMP" "$DEST/latest"
		;;
	esac
	echo "published $n packages to $DEST/$STAMP (latest -> $STAMP)"
fi
echo
echo "Repositories of this build (feed it to a unit that does not have its image's distfeeds):"
echo "  ${target}/packages.adb"
[ -z "$kmods" ] || echo "  ${kmods}/packages.adb"
for d in "$TMP/$pkgdir"/*; do
	[ -d "$d" ] || continue
	echo "  ${pkgdir}/$(basename "$d")/packages.adb"
done
echo
echo "The next build's image points at this tree when it is started with"
echo "  AIR6_REPO_BASE=<URL of $DEST> ./build.sh start --all-packages"
