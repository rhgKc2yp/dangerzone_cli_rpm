# Dangerzone CLI-only Fedora 45 RPM — GitHub Actions

Use this in **your own GitHub repository**, not the upstream Dangerzone repository.

## Repository layout

```text
.github/workflows/dangerzone-cli-rpm.yml
scripts/build-dangerzone-cli-f45.sh
README.md
```

## Set up

1. Create a GitHub repository. Put the files above in the **default branch** (usually `main`) with the exact directory structure.
2. Open **Actions → Dangerzone CLI RPM (Fedora 45) → Run workflow** for an optional manual run. An empty `upstream_tag` uses the latest upstream stable Release. A manually entered tag must look like `v0.11.1`.
3. The workflow checks upstream releases every 6 hours (`17 */6 * * *`, UTC). Schedules are approximate and can be delayed. Releasing a new upstream version does not trigger an instantaneous push event in your repository.
4. Once an eligible upstream release is detected, the workflow builds inside **Docker's Fedora 45 x86_64 image**, publishes a temporary **Actions artifact** and then publishes the RPM plus evidence to your repository's **Releases**.
5. If GitHub rejects publishing with HTTP 403, check repository/organization restrictions for **Settings → Actions → General → Workflow permissions**. The publish job requests `contents: write`. No personal access token is necessary under normal settings.

## Version behavior

The original uploaded script was deliberately pinned to **0.11.1**. It also mistakenly expected *four* `tesseract-langpack-eng` entries; the upstream SPEC currently contains one, so this package corrects that check to **one**. This adapted script accepts `DANGERZONE_VERSION` and checks that both the upstream source version and resulting RPM version match. The workflow pins source to the upstream Release tag (`DANGERZONE_REF=vX.Y.Z`), rather than using the moving `main` branch.

The workflow **ignores versions older than 0.11.1** (the baseline for this patch), and ignores prereleases. **As of October 22, 2026**, the upstream's latest official Release listed on GitHub was `v0.11.0`, while the `main` branch reported `0.11.1`. Thus, the scheduled workflow initially *skips* until an eligible official release is published.

When upstream publishes new changes to the RPM SPEC, `pyproject.toml` or layout, this script deliberately **fails** if the old patch assumptions no longer match. Update the patch by reviewing the upstream changes; it is not safe to apply arbitrary rewrites blindly.

Each successful package is published once under a local tag like `cli-v0.11.1-fc45`. The existence of that Release prevents duplicate builds. Failed builds without a published Release retry at the next check. If you want to rebuild an already published version, delete the corresponding local Release/tag first (and be mindful that existing consumers may have downloaded it).

## Build outputs

- `dangerzone-cli-<version>-*.fc45.x86_64.rpm`: unsigned, unofficial binary RPM
- `*.sha256`: hash manifest
- `*.requires.txt`: RPM runtime dependencies
- `*.files.txt`: package file list
- `*.source.patch`: tracked-source modifications
- `*.buildinfo.txt`: original commit, architecture, variant and build properties

No need to build packages on a Fedora Silverblue host; the workflow installs only build dependencies inside its short-lived Fedora container. The package still requires compatible host dependencies at install/runtime, including Podman; `dangerzone-image upgrade` initializes the verified sandbox image. The workflow does **not** run functional PDF-conversion tests or sign the RPM. Inspect the evidence before installing or redistributing.

## Security characteristics

- The **build** job has only `contents: read`, checks out with `persist-credentials: false`, and does **not** receive a token capable of pushing to your repository.
- The **publish** job has `contents: write` and only consumes the resulting artifacts; it does not execute upstream source code.
- Release tags are an upstream-to-local release signal and are not independently signature-verified by this workflow.
- Builds use the mutable `fedora:45` image reference, so results are not guaranteed bit-for-bit reproducible across time. Pin the image digest for stricter reproducibility.

## Testing locally in Fedora Toolbox

```bash
DANGERZONE_VERSION=0.11.1 DANGERZONE_REF=main \
  bash scripts/build-dangerzone-cli-f45.sh
```

That tests the current `main` branch (which may move), **not** the official release watcher. For CI, an official `vX.Y.Z` release tag is used instead.
