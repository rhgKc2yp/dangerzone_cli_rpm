#!/usr/bin/env bash
# Build an unofficial Dangerzone CLI-only RPM on Fedora 45 (x86_64).
# Designed for Fedora Toolbox: NO build tools are installed on the Silverblue host.
# Changes to upstream: remove GUI/PySide6/Shiboken6; retain only eng Tesseract RPM dependencies; extend Python range for F45;
# retain all other runtime dependencies and Dangerzone's cosign image verification.
set -Eeuo pipefail

EXPECTED_VERSION="${DANGERZONE_VERSION:-0.11.1}"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid DANGERZONE_VERSION' >&2; exit 1; }
REPO='https://github.com/freedomofpress/dangerzone.git'
REF="${DANGERZONE_REF:-main}"   # CI always passes an official release tag (vX.Y.Z).
OUT_DIR="${DANGERZONE_OUT_DIR:-$HOME/dangerzone-cli-rpms}"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"
RESUME_WORKDIR="${DANGERZONE_RESUME_WORKDIR:-}"
# Do not remove an existing work directory when resuming a failed build.
[[ -z "$RESUME_WORKDIR" ]] || KEEP_WORKDIR=1
WORKDIR=''

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
        if [[ "$rc" -eq 0 && "$KEEP_WORKDIR" != 1 ]]; then
            rm -rf -- "$WORKDIR"
        else
            printf '\nBuild work directory retained: %s\n' "$WORKDIR" >&2
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT

if [[ "${1:-}" == '--help' || "${1:-}" == '-h' ]]; then
    cat <<'HELP'
Usage (inside a Fedora 45 Toolbox container):
  bash build-dangerzone-cli-f45.sh

Optional environment variables:
  DANGERZONE_REF=main           Git ref/commit to build (CI pins a release tag)
  DANGERZONE_VERSION=0.11.1     Expected source/RPM version
  DANGERZONE_OUT_DIR=...       Where to copy finished RPMs and build evidence
  KEEP_WORKDIR=1               Keep checked-out source/build directory
  DANGERZONE_RESUME_WORKDIR=...  Resume prepared sources from a failed run

Produces an UNSIGNED, UNOFFICIAL dangerzone-cli-<version>-*.fc45.x86_64.rpm.
Requires a network connection to Fedora repos, GitHub, and the cosign asset.
HELP
    exit 0
fi
[[ "$#" -eq 0 ]] || die 'Unknown argument (run --help)'

# Explicitly guard against accidentally using DNF on the immutable host.
if [[ ! -e /run/.toolboxenv && ! -e /run/.containerenv && ! -e /.dockerenv ]]; then
    die 'Run this INSIDE a Toolbox/Podman container, not on the Silverblue host.'
fi
command -v dnf >/dev/null || die 'Fedora DNF not found.'
command -v rpm >/dev/null || die 'RPM not found.'
[[ "$(rpm --eval '%{fedora}')" == '45' ]] || die 'Expected a Fedora 45 build container.'
[[ "$(uname -m)" == 'x86_64' ]] || die 'This script currently supports only x86_64 (cosign is pinned for linux/amd64).'

say 'Install build-only prerequisites INSIDE Toolbox'
if (( EUID == 0 )); then
    dnf install -y \
        git rpm-build python3 python3-devel python3-build \
        python3-poetry-core pyproject-rpm-macros
else
    sudo dnf install -y \
        git rpm-build python3 python3-devel python3-build \
        python3-poetry-core pyproject-rpm-macros
fi

mkdir -p -- "$OUT_DIR"
if [[ -n "$RESUME_WORKDIR" ]]; then
    [[ -d "$RESUME_WORKDIR/dangerzone/.git" ]] || die "No checked-out Dangerzone source under $RESUME_WORKDIR"
    WORKDIR="$(realpath -e -- "$RESUME_WORKDIR")"
    SRC="$WORKDIR/dangerzone"
    say "Resume previously prepared source: $WORKDIR"
else
    WORKDIR="$(mktemp -d "$HOME/dangerzone-cli-build.XXXXXXXX")"
    SRC="$WORKDIR/dangerzone"
    say "Clone upstream Dangerzone ($REF)"
    if [[ "$REF" == 'main' || "$REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Release tags are fetched directly, not built from the moving main branch.
        git clone --depth 1 --single-branch --branch "$REF" "$REPO" "$SRC"
    else
        # Preserve support for a pinned commit/SHA in local workflows.
        git clone --depth 1 --single-branch --branch main "$REPO" "$SRC"
        git -C "$SRC" fetch --depth 1 origin "$REF"
        git -C "$SRC" checkout --detach FETCH_HEAD
    fi
fi
COMMIT="$(git -C "$SRC" rev-parse HEAD)"
VERSION="$(tr -d '[:space:]' < "$SRC/share/version.txt")"
[[ "$VERSION" == "$EXPECTED_VERSION" ]] || die "Expected source version $EXPECTED_VERSION, found $VERSION at $COMMIT. Pin DANGERZONE_REF to a matching release tag/commit."
printf 'Source: %s\nCommit: %s\n' "$REPO" "$COMMIT"

if [[ -z "$RESUME_WORKDIR" ]]; then
  say 'Patch only GUI packaging, English OCR RPM requirement, and Python 3.15 support'
  python3 - "$SRC" <<'PY'
from pathlib import Path
import re
import shutil
import sys

root = Path(sys.argv[1])
project_path = root / 'pyproject.toml'
spec_path = root / 'install/linux/dangerzone.spec'
builder_path = root / 'install/linux/build-rpm.py'

# Remove the GUI's Python runtime requirements and executable entry point.
project = project_path.read_text()
for pattern, label in (
    (r'(?m)^PySide6\s*=.*\n', 'PySide6'),
    (r'(?m)^shiboken6\s*=.*\n', 'shiboken6'),
    (r'(?m)^dangerzone\s*=\s*"dangerzone\.gui\.run:run"\s*\n', 'GUI entry point'),
):
    project, n = re.subn(pattern, '', project)
    if n != 1:
        raise RuntimeError(f'Unexpected upstream pyproject.toml: {label} matched {n} times')
# Fedora 45 ships Python 3.15.  Upstream SPEC has a matching %prep workaround;
# also update source metadata, since our sdist build runs on Fedora 45.
old_python = 'python = ">=3.10,<3.15"'
if project.count(old_python) != 1:
    raise RuntimeError('Expected Python constraint not found')
project = project.replace(old_python, 'python = ">=3.10,<3.16"')
project_path.write_text(project)

# The CLI doesn't import the GUI package.  Drop its unneeded source files.
gui = root / 'dangerzone/gui'
if not gui.is_dir():
    raise RuntimeError('Expected dangerzone/gui directory missing')
shutil.rmtree(gui)

spec = spec_path.read_text()
# Install as a distinct package; prevent collisions with official distributions.
spec, n = re.subn(r'(?m)^(Name:\s+)dangerzone$', r'\1dangerzone-cli', spec)
if n != 1:
    raise RuntimeError('Unexpected upstream RPM Name field')
old_conflicts = 'Conflicts:      dangerzone-qubes\nConflicts:      dangerzone-full\n%endif'
if spec.count(old_conflicts) != 1:
    raise RuntimeError('Unexpected upstream RPM conflicts block')
spec = spec.replace(old_conflicts,
    'Conflicts:      dangerzone-qubes\nConflicts:      dangerzone-full\nConflicts:      dangerzone\n%endif')

# Only the standard (nonvertical) English Tesseract language is desired.
wanted = {'eng'}
found = []
kept = []
output_lines = []
for line in spec.splitlines(keepends=True):
    match = re.fullmatch(r'Requires:\s+tesseract-langpack-([A-Za-z0-9_]+)', line.strip())
    if match:
        lang = match.group(1)
        found.append(lang)
        if lang not in wanted:
            continue
        kept.append(lang)
    # Remove desktop integration and the GUI executable (keep other resources).
    if line.strip() in {
        'install -pm 755 -d %{buildroot}/usr/share/applications/',
        'install -pm 755 -d %{buildroot}/usr/share/pixmaps/',
        'install -pm 644 install/linux/press.freedom.dangerzone.desktop %{buildroot}/usr/share/applications/',
        'install -pm 644 install/linux/press.freedom.dangerzone.png %{buildroot}/usr/share/pixmaps/',
        '/usr/bin/dangerzone',
    }:
        continue
    output_lines.append(line)
if len(found) < 100 or set(kept) != wanted or len(kept) != 1:
    raise RuntimeError(f'Unexpected upstream Tesseract requires: total={len(found)}, kept={kept}')
spec_path.write_text(''.join(output_lines))

# Upstream build helper uses Poetry ONLY to build an sdist. Fedora's
# python3-build + poetry-core can do that without installing Poetry/pipx.
builder = builder_path.read_text()
old = '["poetry", "build", "-f", "sdist"]'
new = '["python3", "-m", "build", "--sdist", "--no-isolation"]'
if builder.count(old) != 1:
    raise RuntimeError('Unexpected upstream build-rpm.py sdist command')
builder_path.write_text(builder.replace(old, new))

print('Disabled: PySide6, shiboken6, GUI command, GUI source, desktop launcher')
print('OCR Requires retained:', ', '.join(sorted(kept)))
print('All other Python runtime requirements and Podman requirement untouched')
PY

  say 'Fetch pinned cosign Linux binary from upstream mazette.lock (SHA-256 verified)'
# The normal `mazette install` fetches many assets unnecessary for an RPM.
# The Fedora slim RPM does however need the cosign verifier under share/vendor/.
python3 - "$SRC" <<'PY'
from pathlib import Path
import hashlib
import json
import os
import sys
import urllib.request

root = Path(sys.argv[1])
entry = json.loads((root / 'mazette.lock').read_text())['assets']['cosign']['linux/amd64']
url = entry['download_url']
expected = entry['checksum'].lower()
if not url.startswith('https://') or len(expected) != 64:
    raise RuntimeError('Unexpected cosign asset metadata')
destination = root / 'share/vendor/cosign'
destination.parent.mkdir(parents=True, exist_ok=True)
request = urllib.request.Request(url, headers={'User-Agent': 'dangerzone-cli-fedora45-rpm-builder'})
hashobj = hashlib.sha256()
with urllib.request.urlopen(request, timeout=180) as response, destination.open('wb') as dst:
    while True:
        chunk = response.read(1024 * 1024)
        if not chunk:
            break
        hashobj.update(chunk)
        dst.write(chunk)
if hashobj.hexdigest().lower() != expected:
    destination.unlink(missing_ok=True)
    raise RuntimeError('cosign SHA-256 mismatch: refusing to use unverified executable')
os.chmod(destination, 0o755)
print('cosign checksum OK:', expected)
PY
fi

# Upstream argparse uses a Path default, but returns str for an explicit
# --build-dir value. Normalize in main before calling build() (idempotent).
# This fixes AttributeError: 'str' object has no attribute 'mkdir'.
say 'Fix --build-dir Path type and check resumed source configuration'
python3 - "$SRC" <<'PY'
from pathlib import Path
import hashlib
import json
import re
import sys
src = Path(sys.argv[1])
builder_path = src / 'install/linux/build-rpm.py'
builder = builder_path.read_text()
old = 'build(args.build_dir, args.qubes, args.full)'
new = 'build(Path(args.build_dir), args.qubes, args.full)'
if new not in builder:
    if builder.count(old) != 1:
        raise RuntimeError('Unexpected upstream build-rpm.py main() call')
    builder_path.write_text(builder.replace(old, new))
    print('Patched upstream build-dir type mismatch')
else:
    print('build-dir type fix already present')

project = (src / 'pyproject.toml').read_text()
for bad in ('PySide6 =', 'shiboken6 =', 'dangerzone = "dangerzone.gui.run:run"'):
    if bad in project:
        raise RuntimeError(f'GUI entry/dependency still present: {bad}')
if (src / 'dangerzone/gui').exists():
    raise RuntimeError('GUI package not removed')
spec = (src / 'install/linux/dangerzone.spec').read_text()
if not re.search(r'(?m)^Name:\s+dangerzone-cli$', spec):
    raise RuntimeError('Not the renamed CLI-only RPM spec')
langs = re.findall(r'(?m)^Requires:\s+tesseract-langpack-([\w]+)\s*$', spec)
if len(langs) != 1 or set(langs) != {'eng'}:
    raise RuntimeError(f'Wrong OCR language dependencies: {langs}')
lock = json.loads((src / 'mazette.lock').read_text())
expected = lock['assets']['cosign']['linux/amd64']['checksum'].lower()
cosign = src / 'share/vendor/cosign'
if not cosign.is_file() or hashlib.sha256(cosign.read_bytes()).hexdigest().lower() != expected:
    raise RuntimeError('Missing or checksum-invalid cosign verifier')
print('Resumable source checks passed; OCR packs: ', ', '.join(sorted(langs)))
PY

say 'Build Fedora 45 CLI-only RPM with upstream rpmbuild helper'
export SOURCE_DATE_EPOCH="$(git -C "$SRC" log -1 --format=%ct)"
(
    cd "$SRC"
    ./install/linux/build-rpm.py --build-dir "$WORKDIR/rpmbuild"
)

say 'Inspect resulting package (fail closed if GUI dependencies slipped in)'
mapfile -t RPM_FILES < <(find "$SRC/dist" -maxdepth 1 -type f -name 'dangerzone-cli-*.x86_64.rpm' -print | sort)
[[ "${#RPM_FILES[@]}" == 1 ]] || die "Expected exactly one x86_64 CLI RPM, found ${#RPM_FILES[@]}"
BUILT_RPM="${RPM_FILES[0]}"
RPM_NAME="$(rpm -qp --qf '%{NAME}' "$BUILT_RPM")"
[[ "$RPM_NAME" == 'dangerzone-cli' ]] || die "Wrong RPM package name: $RPM_NAME"
RPM_VERSION="$(rpm -qp --qf '%{VERSION}' "$BUILT_RPM")"
[[ "$RPM_VERSION" == "$EXPECTED_VERSION" ]] || die "Wrong RPM version: $RPM_VERSION (expected $EXPECTED_VERSION)"
REQS="$WORKDIR/requirements.txt"
FILELIST="$WORKDIR/files.txt"
rpm -qp --requires "$BUILT_RPM" > "$REQS"
rpm -qpl "$BUILT_RPM" > "$FILELIST"
if grep -Ei '(pyside|shiboken|(^|[^[:alnum:]])qt6?([^[:alnum:]]|$))' "$REQS"; then
    die 'GUI/Qt runtime requirement detected in resulting RPM'
fi
if grep -Eq '(/usr/bin/dangerzone$|/usr/share/applications/|/usr/share/pixmaps/|/dangerzone/gui/)' "$FILELIST"; then
    die 'GUI executable, desktop files, or GUI Python files detected in RPM'
fi
for mandatory in \
    /usr/bin/dangerzone-cli \
    /usr/bin/dangerzone-image \
    /usr/share/dangerzone/vendor/cosign \
    /usr/share/dangerzone/version.txt; do
    grep -Fxq "$mandatory" "$FILELIST" || die "Critical file missing from RPM: $mandatory"
done
grep -Eq '^podman([[:space:]]|$)' "$REQS" || die 'Podman runtime dependency missing'
python3 - "$REQS" <<'PY'
from pathlib import Path
import re
import sys
requires = Path(sys.argv[1]).read_text().splitlines()
langs = {m.group(1) for line in requires if (m := re.fullmatch(r'tesseract-langpack-([A-Za-z0-9_]+)', line.strip()))}
want = {'eng'}
if langs != want:
    raise SystemExit(f'Wrong language pack requirements: {sorted(langs)} (expected {sorted(want)})')
print('Validated OCR dependency set:', ', '.join(sorted(langs)))
PY

target="$OUT_DIR/$(basename "$BUILT_RPM")"
cp -f -- "$BUILT_RPM" "$target"
cp -f -- "$REQS" "$OUT_DIR/$(basename "$BUILT_RPM").requires.txt"
cp -f -- "$FILELIST" "$OUT_DIR/$(basename "$BUILT_RPM").files.txt"
git -C "$SRC" diff --binary > "$OUT_DIR/$(basename "$BUILT_RPM").source.patch"
{
    printf 'Upstream: %s\n' "$REPO"
    printf 'Git ref requested: %s\n' "$REF"
    printf 'Git commit: %s\n' "$COMMIT"
    printf 'Fedora: 45\n'
    printf 'Architecture: x86_64\n'
    printf 'Variant: CLI-only; OCR eng\n'
    printf 'Package signed: no (local build)\n'
} > "$OUT_DIR/$(basename "$BUILT_RPM").buildinfo.txt"
(cd "$OUT_DIR" && sha256sum "$(basename "$BUILT_RPM")" > "$(basename "$BUILT_RPM").sha256")

say 'BUILD SUCCEEDED — RPM copied into shared home directory'
printf '\nRPM: %s\nUpstream commit: %s\n' "$target" "$COMMIT"
printf '\nOn the SILVERBLUE HOST (exit Toolbox first):\n'
printf '  rpm-ostree install --dry-run "%s"\n' "$target"
printf '  rpm-ostree install "%s"\n' "$target"
printf '  systemctl reboot\n'
printf '\nAfter reboot, initialize verified sandbox image:\n'
printf '  dangerzone-image upgrade\n'
printf '  dangerzone-cli --version\n'
printf '  dangerzone-cli --help\n'
