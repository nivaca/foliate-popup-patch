# foliate-no-selection-popup.sh

Disables the text-selection popover menu in [Foliate](https://johnfactotum.github.io/foliate/)
(the GNOME e-book reader) by patching and rebuilding its compiled
GResource bundle.

Foliate normally shows a small popover (dictionary lookup, copy,
highlight, etc.) whenever you select text in the book viewer. This
script builds a patched copy of Foliate's GResource with that popover
disabled, and installs it over the distro-provided one — without
touching the installed RPM itself.

## How it works

1. Reads the exact Foliate version/release currently installed
   (`rpm -q`) and downloads the **matching Fedora source RPM** for
   that exact build (`dnf5 download --source`).
2. Extracts the source RPM, then the two archives inside it:
   - the main `foliate-<version>.tar.gz`
   - the vendored `foliate-js-*.tar.gz` (bundled separately from the
     main tarball, but required to rebuild the resources)
3. Patches `src/book-viewer.js`: comments out the call that shows the
   selection popover. The patch only applies if it finds an **exact**
   match for the surrounding code; if a Foliate update changed that
   code, the script stops with an error instead of guessing.
4. Recompiles `src/gresource.xml` into a new `.gresource` file with
   `glib-compile-resources`.
5. Backs up the currently installed (pristine) GResource file the
   first time it runs, then installs the patched build with `sudo`.

## Requirements

- Fedora, with `dnf5`, `rpm`, `rpm2cpio`, `cpio`, `tar`,
  `glib-compile-resources` (from `glib2-devel` or similar), and
  `python3` on `PATH`.
- **Fedora's source repositories enabled.** These are off by default:

  ```sh
  sudo dnf5 config-manager setopt fedora-source.enabled=1
  sudo dnf5 config-manager setopt updates-source.enabled=1
  ```

- `sudo` rights to write under `/usr/share`.
- Network access to Fedora's package repositories.

## Usage

```sh
# Build and install the patch
./foliate-no-selection-popup.sh

# Restore the original, unpatched GResource
./foliate-no-selection-popup.sh --uninstall
```

Restart Foliate after either command for the change to take effect.

## Files this script touches

| Path | Purpose |
|---|---|
| `/usr/share/com.github.johnfactotum.Foliate/com.github.johnfactotum.Foliate.gresource` | The live, patched resource file |
| `<above>.orig` | One-time backup of the original, pristine file |
| `<above>.orig.version` | Records which Foliate version the backup came from |

Everything else happens in a temporary directory that is deleted when
the script exits.

## Known limitation: backup drift after a Foliate update

The backup is only ever taken **once** — the first time the script
successfully patches your system. If `dnf` later upgrades Foliate to
a new version, that upgrade overwrites the installed `.gresource`
file with a fresh, unpatched one — but your `.orig` backup still
holds the *old* version.

The script records the source version next to the backup and will
print a warning at startup if the two no longer match, e.g.:

```
WARNING: Existing backup was taken from Foliate 3.2.0-1.fc41,
         but 3.3.0-1.fc41 is currently installed.
         --uninstall would restore the WRONG version.
```

If you see that warning, the safest fix is:

```sh
sudo dnf5 reinstall foliate
rm /usr/share/com.github.johnfactotum.Foliate/com.github.johnfactotum.Foliate.gresource.orig
rm /usr/share/com.github.johnfactotum.Foliate/com.github.johnfactotum.Foliate.gresource.orig.version
```

then re-run the script to patch the current version and record a
fresh, matching backup.

## Undoing the patch

```sh
./foliate-no-selection-popup.sh --uninstall
```

This copies `.orig` back over the live GResource file. It does not
delete the `.orig`/`.orig.version` files, so you can re-apply the
patch again later without re-triggering the "creating backup" step.
