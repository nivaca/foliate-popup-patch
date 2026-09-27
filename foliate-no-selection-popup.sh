#!/usr/bin/env bash
#
# foliate-no-selection-popup.sh
# ==============================
#
# PURPOSE
#   Foliate (the GNOME e-book reader) shows a small popover menu
#   whenever text is selected in the book viewer. This script builds
#   a patched copy of Foliate's compiled GResource bundle with that
#   popover disabled, and installs it in place of the distro-provided
#   one.
#
# HOW IT WORKS
#   1. Finds the exact Foliate version/release currently installed
#      (via `rpm -q`) and downloads the matching Fedora *source* RPM
#      for that exact build with `dnf5 download --source`.
#   2. Extracts the source RPM, then the two tarballs inside it:
#      the main `foliate-<version>.tar.gz` and the vendored
#      `foliate-js-*.tar.gz` (the bundled foliate-js library, which
#      is not part of the main tarball but is required to rebuild
#      the GResource).
#   3. Applies a one-line patch to `src/book-viewer.js`: the code
#      that would call `this._view.showPopover(...)` after a
#      selection is made is commented out. The patch matches an
#      exact, multi-line block of source text and aborts instead of
#      guessing if that block isn't found verbatim (e.g. because a
#      Foliate update changed the surrounding code).
#   4. Recompiles `src/gresource.xml` with `glib-compile-resources`
#      into a new `.gresource` file.
#   5. Backs up the *currently installed* (pristine) GResource to
#      `<resource>.orig` the first time it runs, then installs the
#      patched build over the system path with `sudo`.
#
# REQUIREMENTS
#   - Fedora with `dnf5`, plus `rpm`, `rpm2cpio`, `cpio`, `tar`,
#     `glib-compile-resources` (from glib2-devel or similar) and
#     `python3` on PATH.
#   - Fedora's *source* repositories must be enabled, or
#     `dnf5 download --source` will find nothing to download. On a
#     stock Fedora install these are disabled by default; enable
#     them with something like:
#       sudo dnf5 config-manager setopt fedora-source.enabled=1
#       sudo dnf5 config-manager setopt updates-source.enabled=1
#   - `sudo` rights to write under /usr/share.
#   - Network access to Fedora's package repositories.
#
# USAGE
#   ./foliate-no-selection-popup.sh            # build + install the patch
#   ./foliate-no-selection-popup.sh --uninstall # restore the original file
#
# CAVEAT: BACKUP VS. INSTALLED-VERSION DRIFT
#   The backup is only ever taken once, the first time the script
#   runs successfully. If Foliate is later upgraded by `dnf` (which
#   will silently overwrite the GResource file, patched or not, with
#   the new version's pristine one), the `.orig` backup on disk still
#   holds the *old* version. Re-running this script at that point
#   will patch the new version correctly, but `--uninstall` would
#   then restore the *old* version's GResource instead of the
#   currently-installed one. The script now records the source
#   package's version/release next to the backup and warns you if
#   they no longer match (see below) — but it cannot fix the backup
#   for you. If you see that warning, the safest fix is to
#   reinstall/repair the Foliate package (e.g. `sudo dnf5 reinstall
#   foliate`) to get a fresh pristine file, remove the stale
#   `.orig`/`.version` files, and re-run this script.
#
set -euo pipefail

RESOURCE="/usr/share/com.github.johnfactotum.Foliate/com.github.johnfactotum.Foliate.gresource"
BACKUP="${RESOURCE}.orig"
BACKUP_VERSION_FILE="${BACKUP}.version"

# ------------------------------------------------------------
# --uninstall
# ------------------------------------------------------------

if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ $# -ne 1 ]]; then
        echo "Usage: $0 [--uninstall]"
        exit 1
    fi

    if [[ ! -f "$BACKUP" ]]; then
        echo "ERROR: Backup not found:"
        echo "  $BACKUP"
        exit 1
    fi

    echo "Restoring original Foliate GResource..."
    sudo cp -a "$BACKUP" "$RESOURCE"

    if [[ -f "$BACKUP_VERSION_FILE" ]]; then
        echo "(Restored backup was taken from Foliate $(cat "$BACKUP_VERSION_FILE").)"
    fi

    echo
    echo "Original Foliate GResource restored."
    echo "Restart Foliate before testing."
    exit 0
fi

if [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--uninstall]"
    exit 1
fi

# ------------------------------------------------------------
# Required commands
# ------------------------------------------------------------

for command in dnf5 rpm rpm2cpio cpio tar \
                    glib-compile-resources python3; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $command"
        exit 1
    fi
done

# ------------------------------------------------------------
# Check installed GResource
# ------------------------------------------------------------

if [[ ! -f "$RESOURCE" ]]; then
    echo "ERROR: Installed Foliate GResource not found:"
    echo "  $RESOURCE"
    exit 1
fi

# ------------------------------------------------------------
# Temporary workspace
# ------------------------------------------------------------

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

SRPMDIR="$WORKDIR/srpm"
SOURCEDIR="$WORKDIR/source"
JS_WORK="$WORKDIR/foliate-js"

mkdir -p "$SRPMDIR" "$SOURCEDIR" "$JS_WORK"

echo "Foliate selection-popup patch"
echo
echo "Installed GResource:"
echo "  $RESOURCE"
echo

# ------------------------------------------------------------
# Determine installed Foliate version
# ------------------------------------------------------------

VERSION="$(rpm -q --qf '%{VERSION}\n' foliate)"
RELEASE="$(rpm -q --qf '%{RELEASE}\n' foliate)"

if [[ -z "$VERSION" || -z "$RELEASE" ]]; then
    echo "ERROR: Could not determine installed Foliate version."
    exit 1
fi

echo "Installed Foliate:"
echo "  ${VERSION}-${RELEASE}"
echo

# Warn if a backup already exists but was taken from a different
# Foliate build than the one currently installed. This usually means
# Foliate was updated by dnf after the patch was applied, so the
# on-disk .orig backup is stale (see header comment).
if [[ -f "$BACKUP" && -f "$BACKUP_VERSION_FILE" ]]; then
    RECORDED_VERSION="$(cat "$BACKUP_VERSION_FILE")"
    if [[ "$RECORDED_VERSION" != "${VERSION}-${RELEASE}" ]]; then
        echo "WARNING: Existing backup was taken from Foliate ${RECORDED_VERSION},"
        echo "         but ${VERSION}-${RELEASE} is currently installed."
        echo "         --uninstall would restore the WRONG version."
        echo "         Consider 'sudo dnf5 reinstall foliate' and removing:"
        echo "           $BACKUP"
        echo "           $BACKUP_VERSION_FILE"
        echo "         before continuing."
        echo
    fi
elif [[ -f "$BACKUP" && ! -f "$BACKUP_VERSION_FILE" ]]; then
    echo "NOTE: A backup exists from an earlier version of this script"
    echo "      (no recorded version). Its version could not be checked."
    echo
fi

# ------------------------------------------------------------
# Download matching source RPM
# ------------------------------------------------------------

echo "Downloading matching Fedora source RPM..."

(
    cd "$SRPMDIR"
    dnf5 download --source "foliate-${VERSION}-${RELEASE}"
)

SRPM="$(find "$SRPMDIR" -maxdepth 1 -type f \
    -name 'foliate-*.src.rpm' \
    -print -quit)"

if [[ -z "$SRPM" ]]; then
    echo "ERROR: Could not find downloaded Foliate source RPM."
    echo "       This usually means Fedora's source repositories are"
    echo "       disabled, or this exact build (${VERSION}-${RELEASE})"
    echo "       is no longer available. Try:"
    echo "         sudo dnf5 config-manager setopt fedora-source.enabled=1"
    echo "         sudo dnf5 config-manager setopt updates-source.enabled=1"
    exit 1
fi

echo "Source RPM:"
echo "  $SRPM"
echo

# ------------------------------------------------------------
# Extract source RPM
# ------------------------------------------------------------

echo "Extracting source RPM..."

(
    cd "$SOURCEDIR"
    rpm2cpio "$SRPM" | cpio -idm
)

# ------------------------------------------------------------
# Locate source archives
# ------------------------------------------------------------

MAIN_TARBALL="$(
    find "$SOURCEDIR" -maxdepth 1 -type f \
        -name "foliate-${VERSION}.tar.gz" \
        -print -quit
)"

if [[ -z "$MAIN_TARBALL" ]]; then
    echo "ERROR: Could not find:"
    echo "  foliate-${VERSION}.tar.gz"
    exit 1
fi

JS_TARBALL="$(
    find "$SOURCEDIR" -maxdepth 1 -type f \
        -name 'foliate-js-*.tar.gz' \
        -print -quit
)"

if [[ -z "$JS_TARBALL" ]]; then
    echo "ERROR: Could not find foliate-js source archive."
    exit 1
fi

echo "Main source archive:"
echo "  $MAIN_TARBALL"
echo
echo "foliate-js archive:"
echo "  $JS_TARBALL"
echo

# ------------------------------------------------------------
# Extract main Foliate source
# ------------------------------------------------------------

echo "Extracting main Foliate source..."

tar -xzf "$MAIN_TARBALL" -C "$SOURCEDIR"

FOLIATE_SOURCE="$SOURCEDIR/foliate-${VERSION}"

if [[ ! -d "$FOLIATE_SOURCE" ]]; then
    echo "ERROR: Could not find extracted Foliate source directory:"
    echo "  $FOLIATE_SOURCE"
    exit 1
fi

echo "Foliate source:"
echo "  $FOLIATE_SOURCE"
echo

# ------------------------------------------------------------
# Extract foliate-js
# ------------------------------------------------------------

echo "Extracting foliate-js..."

tar -xzf "$JS_TARBALL" -C "$JS_WORK"

JS_DIR="$(
    find "$JS_WORK" -mindepth 1 -maxdepth 1 \
        -type d \
        -print -quit
)"

if [[ -z "$JS_DIR" ]]; then
    echo "ERROR: Could not find extracted foliate-js directory."
    exit 1
fi

if [[ ! -f "$JS_DIR/comic-book.js" ]]; then
    echo "ERROR: Extracted foliate-js directory does not contain:"
    echo "  comic-book.js"
    exit 1
fi

# IMPORTANT:
# gresource.xml expects foliate-js relative to src/,
# so install it as src/foliate-js/.

rm -rf "$FOLIATE_SOURCE/src/foliate-js"

mv "$JS_DIR" "$FOLIATE_SOURCE/src/foliate-js"

echo "foliate-js installed at:"
echo "  $FOLIATE_SOURCE/src/foliate-js"
echo

# ------------------------------------------------------------
# Verify required files
# ------------------------------------------------------------

MANIFEST="$FOLIATE_SOURCE/src/gresource.xml"
BOOK_VIEWER="$FOLIATE_SOURCE/src/book-viewer.js"
COMIC_BOOK="$FOLIATE_SOURCE/src/foliate-js/comic-book.js"

if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: Resource manifest not found:"
    echo "  $MANIFEST"
    exit 1
fi

if [[ ! -f "$BOOK_VIEWER" ]]; then
    echo "ERROR: book-viewer.js not found:"
    echo "  $BOOK_VIEWER"
    exit 1
fi

if [[ ! -f "$COMIC_BOOK" ]]; then
    echo "ERROR: comic-book.js not found:"
    echo "  $COMIC_BOOK"
    exit 1
fi

# ------------------------------------------------------------
# Patch book-viewer.js
# ------------------------------------------------------------

echo "Patching book-viewer.js..."

python3 - "$BOOK_VIEWER" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

if "// Selection popup disabled." in text:
    print("Selection popup is already disabled.")
    sys.exit(0)

old = """            utils.connect(popover, {
                'show-popover': (_, popover) =>
                    this._view.showPopover(popover, point, dir),
                'run-tool': () => ({ text, lang }),
                // it seems `closed` is emitted before the actions are run
                // so it needs the timeout
                'closed': () => setTimeout(() => resolved ? null : resolve(), 0),
            })
            this._view.showPopover(popover, point, dir)
"""

new = """            utils.connect(popover, {
                'show-popover': (_, popover) =>
                    this._view.showPopover(popover, point, dir),
                'run-tool': () => ({ text, lang }),
                // it seems `closed` is emitted before the actions are run
                // so it needs the timeout
                'closed': () => setTimeout(() => resolved ? null : resolve(), 0),
            })
            // Selection popup disabled.
"""

count = text.count(old)

if count != 1:
    print(f"ERROR: Expected exactly one selection-popup block; found {count}.")
    sys.exit(1)

path.write_text(text.replace(old, new, 1))
print("Selection popup disabled successfully.")
PY

# ------------------------------------------------------------
# Rebuild GResource
# ------------------------------------------------------------

echo
echo "Rebuilding GResource..."

(
    cd "$FOLIATE_SOURCE"

    glib-compile-resources \
        src/gresource.xml \
        --sourcedir=src \
        --target="$WORKDIR/Foliate.gresource"
)

if [[ ! -s "$WORKDIR/Foliate.gresource" ]]; then
    echo "ERROR: Rebuilt GResource is empty or missing."
    exit 1
fi

echo "GResource rebuilt successfully."
echo

# ------------------------------------------------------------
# Back up installed GResource
# ------------------------------------------------------------

if [[ ! -f "$BACKUP" ]]; then
    echo "Creating backup:"
    echo "  $BACKUP"

    sudo cp -a "$RESOURCE" "$BACKUP"
    echo "${VERSION}-${RELEASE}" | sudo tee "$BACKUP_VERSION_FILE" >/dev/null
else
    echo "Existing backup preserved:"
    echo "  $BACKUP"
fi

# ------------------------------------------------------------
# Install patched GResource
# ------------------------------------------------------------

echo "Installing patched GResource..."

sudo cp -a "$WORKDIR/Foliate.gresource" "$RESOURCE"

echo
echo "=============================================="
echo " Foliate selection popup disabled."
echo "=============================================="
echo
echo "Original backup:"
echo "  $BACKUP"
echo
echo "To restore the original:"
echo "  $0 --uninstall"
echo
echo "Restart Foliate before testing."
