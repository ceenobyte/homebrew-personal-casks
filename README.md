# homebrew-personal-casks

A personal [Homebrew](https://brew.sh) [tap](https://docs.brew.sh/Taps) that keeps casks alive which have been marked `disable!` (or removed) in the official [`homebrew/cask`](https://github.com/Homebrew/homebrew-cask) repository, but which are still needed and can still be installed and updated safely.

Casks in this tap have their upstream `disable!` line kept as a comment for reference, so `brew` treats them as regular, installable casks in this tap.

## Casks in this tap

| Cask | Token | Notes |
| --- | --- | --- |
| [QOwnNotes](Casks/qownnotes.rb) | `qownnotes` | Disabled upstream: `fails_gatekeeper_check` |
| [FreeTube](Casks/freetube.rb) | `freetube` | Disabled upstream: `fails_gatekeeper_check` |
| [OpenEmu](Casks/openemu.rb) | `openemu` | Disabled upstream: `fails_gatekeeper_check` |
| [WineHQ-stable](Casks/wine-stable.rb) | `wine-stable` | Disabled upstream: `fails_gatekeeper_check` |
| [GStreamer runtime package](Casks/gstreamer-runtime.rb) | `gstreamer-runtime` | Disabled upstream: `fails_gatekeeper_check` |

See [Adding a new cask](#adding-a-new-cask) below for how new entries end up in this table.

## Requirements

- macOS with [Homebrew](https://brew.sh) installed.
- [`jq`](https://jqlang.org/) (only required to run `scripts/update-casks.command`):

  ```sh
  brew install jq
  ```

## Installation

Tap this repository once:

```sh
brew tap ceenobyte/personal-casks
```

Then install any cask listed above by its token:

```sh
brew install --cask <token>
```

Because these casks are disabled upstream, `brew install --cask <token>` only works while this tap is active. Homebrew always prefers a tapped cask with the same token over the official (disabled) one, so no extra flags are required.

## Keeping casks up to date

Once installed, casks from this tap participate in the normal Homebrew workflow:

```sh
brew update
brew upgrade
```

`brew update` pulls the latest commits from this tap (and all other taps), and `brew upgrade` installs any newer `version`/`sha256` that has been committed to a cask file here. In other words, updating an app in this tap is a two-step process:

1. Someone (see [`scripts/update-casks.command`](scripts/update-casks.command) below) bumps `version` and `sha256` in the cask file and commits/pushes the change to this repository.
2. Users of the tap run `brew update && brew upgrade` to receive it.

## `scripts/update-casks.command`

This script automates step 1 above: it scans the repository for cask files and bumps any that have a newer upstream release, using Homebrew's own developer tooling rather than reimplementing version/checksum logic.

### What it does

For every `*.rb` file in this repository that defines a cask (`cask "<token>" do`), the script:

1. Runs `brew livecheck <file> --cask --json --newer-only`, which evaluates the `livecheck` block already defined in that cask (e.g. `strategy :github_latest`) to check upstream for a newer version. This is Homebrew's own, officially maintained mechanism for detecting new releases — no custom scraping code required.
2. If a newer version is found, runs `brew bump-cask-pr <file> --version=<new-version> --write-only --no-browse`. `bump-cask-pr` is Homebrew's own version-bump tool: it downloads the new release, computes the correct SHA-256 checksum(s) (including per-architecture/per-OS variants for casks that use `arch arm:`/`intel:` blocks), and rewrites `version`/`sha256` in the cask file. `--write-only` makes sure it only edits the file — it never commits, forks, or opens a pull request.

Newly added cask files are picked up automatically on every run because the script discovers casks by scanning for `cask "..." do` blocks instead of relying on a hardcoded list. There is nothing to register when a new cask is added to this tap.

### Usage

```sh
./scripts/update-casks.command
```

Add `--dry-run` (or `-n`) to only report which casks have a newer version available, without modifying any files:

```sh
./scripts/update-casks.command --dry-run
```

The script never commits or pushes on its own. After a successful run, review the changes and commit them yourself:

```sh
git diff
git add Casks *.rb
git commit -m "Bump <cask> to <version>"
git push
```

Only after pushing will `brew update && brew upgrade` on other machines pick up the new version.

### Troubleshooting

- If `brew livecheck` fails for a cask, the script prints the raw error and continues with the next one; it does not abort the whole run.
- If `brew bump-cask-pr` fails (e.g. the download URL changed in an unexpected way), the affected cask is reported as failed at the end and the script exits with a non-zero status, while still applying any other successful bumps.
- Re-adding an active `disable!`/`deprecate!` line to a cask in this tap will make Homebrew skip it during `livecheck` and refuse `bump-cask-pr`; keep that line commented out if you want this script to keep tracking new versions.

## Adding a new cask

1. Generate a cask skeleton, or copy the upstream definition before it was disabled (e.g. from the [`homebrew-cask` Git history](https://github.com/Homebrew/homebrew-cask/commits/main)).
2. Place the file in `Casks/<token>.rb`, following the [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook) conventions.
3. Make sure it has a working `livecheck` block — this is required for `scripts/update-casks.command` to detect new versions automatically.
4. Comment out (do not delete) any `disable!`/`deprecate!` stanza copied from upstream, keeping the original `date:`/`because:` metadata for reference.
5. Validate the cask locally:

   ```sh
   brew style --cask Casks/<token>.rb
   brew audit --cask Casks/<token>.rb
   brew install --cask Casks/<token>.rb
   ```

6. Commit and push. The next `scripts/update-casks.command` run will automatically include the new cask.

## References

- [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)
- [`brew livecheck` documentation](https://docs.brew.sh/Brew-Livecheck)
- [`brew` manpage](https://docs.brew.sh/Manpage) (see `livecheck` and `bump-cask-pr` under Developer Commands)