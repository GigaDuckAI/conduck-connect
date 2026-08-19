#!/usr/bin/env bash
#
# Deterministically assemble the single-file conduck-connect release artifact.
# Bash 3.2-compatible: this runs on the oldest supported macOS shell.
#
# Modes:
#   (no args)   rebuild conduck-connect.sh from src/ (OVERWRITES the artifact)
#   --check     assert the checked-in artifact matches src/ (CI drift gate)
#   --stdout    write the freshly built artifact to stdout, touching nothing
#   --map       print "module -> first_line_in_artifact" so a diagnostic reported
#               against the generated artifact maps back to the module that owns it
#
# The concatenation is guarded, because every failure below was reproduced as a
# silent build success before these assertions existed:
#   - a module whose name is not *.inc.sh silently never reaching the artifact,
#   - a reordered manifest burying the shebang mid-file (`bash -n` still exits 0),
#   - a module that lost its trailing newline gluing two modules together.

set -euo pipefail

builder_dir=$(
  unset CDPATH
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
  pwd
)
repo_dir=$(
  unset CDPATH
  cd -- "$builder_dir/.."
  pwd
)
manifest="$repo_dir/src/manifest.txt"
artifact="$repo_dir/conduck-connect.sh"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/conduck-connect-build.XXXXXX")
built="$build_dir/conduck-connect.sh"
scratch="$build_dir/rewrite.tmp"

cleanup() {
  rm -f "$built" "$scratch"
  rmdir "$build_dir" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

# Files in src/ that are documentation/build inputs rather than script modules.
# Everything else in src/ MUST be listed in the manifest.
unlisted_allowed='
README.md
manifest.txt
'

# Banner stamped into the generated artifact. It is emitted by the builder, not
# stored in src/, so it can never be mistaken for editable source. It is placed
# just PAST the header comment block that `--help` prints verbatim, so end users
# never get build instructions in their help output (asserted below).
generated_marker='# GENERATED FILE — edit src/*.inc.sh and run scripts/build-release.sh; direct edits are overwritten'
marker_probe='GENERATED FILE — edit src/'

count_lines() { # <file> -> line count, no surrounding whitespace
  wc -l < "$1" | tr -dc '0-9'
}

help_block_of() { # <file> -> exactly what `--help` prints from that file
  sed -n '2,${/^#/!q;s/^# \{0,1\}//p;}' "$1"
}

insert_marker() { # <file> -> stamp the generated-file banner just past the --help header
  # The header block ends at the first line (from line 2 on) that does not start
  # with '#' — that is where --help stops reading, so the banner goes right after
  # it: as close to the top of the file as it can be without polluting --help.
  awk -v marker="$generated_marker" '
    NR == 1 { print; next }
    !stamped && $0 !~ /^#/ { print; print marker; print ""; stamped = 1; next }
    { print }
    END { if (!stamped) exit 3 }
  ' "$1" > "$scratch" || return 1
  cat "$scratch" > "$1"
  rm -f "$scratch"
}

[ -f "$manifest" ] || {
  printf 'error: source manifest is missing: %s\n' "$manifest" >&2
  exit 1
}

: > "$built"
listed_modules="
"
line_map=""
first_module=true
while IFS= read -r module || [ -n "$module" ]; do
  case "$module" in
    ''|'#'*) continue ;;
    *'/'*|*'..'*|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*)
      printf 'error: invalid source module in manifest: %s\n' "$module" >&2
      exit 1
      ;;
  esac
  case "$listed_modules" in
    *"
$module
"*)
      printf 'error: duplicate source module in manifest: %s\n' "$module" >&2
      exit 1
      ;;
  esac
  listed_modules="${listed_modules}${module}
"
  source_file="$repo_dir/src/$module"
  [ -f "$source_file" ] || {
    printf 'error: source module is missing: %s\n' "$source_file" >&2
    exit 1
  }
  # A module missing its final newline glues its last line onto the next module's
  # first line. Best case `bash -n` reports a syntax error thousands of lines
  # away; worst case the last line is a comment, it swallows the next module's
  # first line, and nothing complains at all.
  if [ -s "$source_file" ] && [ -n "$(tail -c 1 "$source_file")" ]; then
    printf 'error: source module does not end with a newline: %s\n' "$source_file" >&2
    printf '       Concatenation would glue its last line onto the first line of the next module.\n' >&2
    exit 1
  fi
  start=$(( $(count_lines "$built") + 1 ))
  cat "$source_file" >> "$built"
  if [ "$first_module" = true ]; then
    first_module=false
    # Checked here, on the first module, so the message can name the real cause.
    # A manifest that lists another module first buries the shebang mid-file and
    # moves `set -u -o pipefail` hundreds of lines down — and `bash -n` still
    # exits 0 on the result, so nothing downstream catches it.
    if [ "$(head -c 2 "$built" 2>/dev/null || true)" != '#!' ]; then
      printf 'error: the built artifact does not start with "#!" (first module: %s).\n' "$module" >&2
      printf '       The module carrying the shebang must be listed FIRST in src/manifest.txt.\n' >&2
      exit 1
    fi
    # Stamped while the artifact is still just this module, so every start line
    # recorded after this point is already banner-adjusted.
    insert_marker "$built" || {
      printf 'error: could not stamp the generated-file banner: no non-comment line found in %s.\n' "$module" >&2
      exit 1
    }
  fi
  line_map="${line_map}${module} -> ${start}
"
done < "$manifest"

# Any file dropped into src/ that the manifest does not list never reaches the
# artifact. Sweeping src/* (not src/*.inc.sh) is deliberate: a contributor who
# names a module 45-helper.sh or 45-helper.bash — the extension every other shell
# file in this repo uses — used to get a clean exit 0 and no warning at all.
for source_file in "$repo_dir"/src/*; do
  [ -e "$source_file" ] || continue
  module=${source_file##*/}
  case "$unlisted_allowed" in
    *"
$module
"*) continue ;;
  esac
  case "$listed_modules" in
    *"
$module
"*) ;;
    *)
      printf 'error: %s is not listed in src/manifest.txt — it was NOT built into the artifact.\n' "$source_file" >&2
      printf '       Add it to src/manifest.txt in build order, or remove it. Only README.md and\n' >&2
      printf '       manifest.txt may stay unlisted.\n' >&2
      exit 1
      ;;
  esac
done

[ -s "$built" ] || {
  printf 'error: the built artifact is empty; src/manifest.txt lists no modules.\n' >&2
  exit 1
}
if [ "$(head -c 2 "$built" 2>/dev/null || true)" != '#!' ]; then
  printf 'error: the built artifact does not start with "#!".\n' >&2
  exit 1
fi
grep -qF "$marker_probe" "$built" || {
  printf 'error: the generated-file banner is missing from the built artifact.\n' >&2
  exit 1
}
if help_block_of "$built" | grep -qF "$marker_probe"; then
  printf 'error: the generated-file banner leaked into --help output.\n' >&2
  printf '       It must sit past the header comment block that --help prints.\n' >&2
  exit 1
fi
chmod 755 "$built"

case "${1:-}" in
  '')
    cp "$built" "$artifact"
    chmod 755 "$artifact"
    printf 'built %s\n' "$artifact"
    ;;
  --check)
    [ -f "$artifact" ] || {
      printf 'error: generated artifact is missing: %s\n' "$artifact" >&2
      exit 1
    }
    if ! cmp -s "$built" "$artifact"; then
      printf 'error: conduck-connect.sh does not match src/.\n' >&2
      printf '       conduck-connect.sh is a GENERATED file. Rebuilding it DISCARDS any edit made\n' >&2
      printf '       directly to it — so do not "fix" this by rebuilding over your own change.\n' >&2
      printf '       If you edited conduck-connect.sh by hand, `git diff conduck-connect.sh` shows\n' >&2
      printf '       exactly what you changed: move that change into the matching src/*.inc.sh\n' >&2
      printf '       module (and src/manifest.txt if you added one) FIRST.\n' >&2
      printf '       Then, and only then:  bash scripts/build-release.sh\n' >&2
      exit 1
    fi
    [ -x "$artifact" ] || {
      printf 'error: generated artifact is not executable: %s\n' "$artifact" >&2
      exit 1
    }
    printf 'source and generated artifact are byte-identical\n'
    ;;
  --stdout)
    cat "$built"
    ;;
  --map)
    # Line numbers in the freshly built artifact, which --check proves identical
    # to the checked-in one. src/*.inc.sh cannot be linted standalone (cross-module
    # variables produce ~50 SC2034 false positives), so CI lints the assembled
    # artifact — this maps its diagnostics back to the owning module.
    printf '%s' "$line_map"
    ;;
  *)
    printf 'usage: bash scripts/build-release.sh [--check|--stdout|--map]\n' >&2
    exit 2
    ;;
esac
