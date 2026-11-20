# homebrew-personal-casks

A personal [Homebrew](https://brew.sh) [tap](https://docs.brew.sh/Taps) that keeps casks alive which have been marked `disable!` (or removed) in the official [`homebrew/cask`](https://github.com/Homebrew/homebrew-cask) repository, but which are still needed and can still be installed and updated safely.

Casks in this tap have their upstream `disable!` line kept as a comment for reference, so `brew` treats them as regular, installable casks in this tap.

## Casks in this tap

| Cask | Token | Notes |
| --- | --- | --- |
| [Angry IP Scanner](Casks/angry-ip-scanner.rb) | `angry-ip-scanner` | Disabled upstream: `fails_gatekeeper_check` |
| [QOwnNotes](Casks/qownnotes.rb) | `qownnotes` | Disabled upstream: `fails_gatekeeper_check` |
| [FreeTube](Casks/freetube.rb) | `freetube` | Disabled upstream: `fails_gatekeeper_check` |
| [MarkText](Casks/mark-text.rb) | `mark-text` | Disabled upstream: `fails_gatekeeper_check` |
| [OpenEmu](Casks/openemu.rb) | `openemu` | Disabled upstream: `fails_gatekeeper_check` |
| [WineHQ-stable](Casks/wine-stable.rb) | `wine-stable` | Disabled upstream: `fails_gatekeeper_check` |
| [GStreamer runtime package](Casks/gstreamer-runtime.rb) | `gstreamer-runtime` | Disabled upstream: `fails_gatekeeper_check` |
| [Zenmap](Casks/zenmap.rb) | `zenmap` | Disabled upstream: `fails_gatekeeper_check` |

See [Adding a new cask](#adding-a-new-cask) below for how new entries end up in this table.

## Requirements

- macOS with [Homebrew](https://brew.sh) installed.
- For publishing updates: a configured Git commit identity and authenticated
  push access to the installed tap's `origin` remote. A separate checkout also
  needs authenticated fetch access to its `origin`.
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

This script automates step 1 above: it scans the installed tap for cask files, bumps any that have a newer upstream release, and commits and pushes successful updates so other clients can receive them. If started from a separate checkout, it then pulls the published changes into that checkout. It uses Homebrew's own developer tooling rather than reimplementing version/checksum logic.

### What it does

For every `*.rb` file in the installed tap that defines a cask (`cask "<token>" do`), the script:

1. Runs `brew livecheck ceenobyte/personal-casks/<token> --cask --json --quiet`, which evaluates the `livecheck` block already defined in that cask (e.g. `strategy :github_latest`) to check upstream for a newer version and distinguish skipped casks from current ones. Homebrew expects a cask name here, not a path to its Ruby file.
2. If a newer version is found, runs `brew bump-cask-pr ceenobyte/personal-casks/<token> --version=<new-version> --write-only --no-browse`. `bump-cask-pr` is Homebrew's own version-bump tool: it downloads the new release, computes the correct SHA-256 checksum(s) (including per-architecture/per-OS variants for casks that use `arch arm:`/`intel:` blocks), and rewrites `version`/`sha256` in the cask file. `--write-only` makes sure it only edits the file — it never commits, forks, or opens a pull request.

After checking all casks, the script creates one commit in the installed tap
containing only successfully updated cask files and pushes it to `origin`'s
default branch (normally `main`, as recorded by `origin/HEAD`). If no cask
files actually changed, it does not commit or push. Failed cask updates are not
included; any changes they left behind remain local for review.

After an entirely successful run, a separate checkout containing the invoked
script is fast-forwarded from its `origin`. This also catches it up when no new
cask update was needed. No pull is performed if any cask check, update, commit,
or push fails. When the script itself is in the installed tap, there is no
separate checkout to pull.

Newly added cask files are picked up automatically on every run because the script discovers casks by scanning for `cask "..." do` blocks instead of relying on a hardcoded list. There is nothing to register when a new cask is added to this tap.

FreeTube supports macOS Sequoia and newer. Upstream currently publishes only
pre-releases, so its updater skips only Homebrew's GitHub pre-release and minimum
OS audit checks; all other online audit checks still run. Review each release
before updating the cask.

### Usage

The script uses fully qualified cask names (for example, `ceenobyte/personal-casks/wine-stable`) so Homebrew can resolve them from the installed tap. It switches to that tap before checking or updating casks. Invoke it from the checkout you want to synchronize:

Review the tap's cask definitions before trusting it. This grants Homebrew permission to load Ruby code from the tap.

```sh
brew trust --tap ceenobyte/personal-casks
cd /path/to/homebrew-personal-casks
./scripts/update-casks.command
```

The script can also be invoked directly from the installed tap:

```sh
cd "$(brew --repository)/Library/Taps/ceenobyte/homebrew-personal-casks"
./scripts/update-casks.command
```

Add `--dry-run` (or `-n`) to only report which casks have a newer version
available, without changing cask files or running Git fetch, commit, push, or
pull:

```sh
./scripts/update-casks.command --dry-run
```

This repository is the single source of truth. When the script is invoked from
a separate checkout, the installed tap is treated as disposable: after the
checks below pass, it is reset to `origin`'s default branch, and local tap
commits, changes, and untracked files outside its `tmp` directory are discarded.
Update commits then use the separate checkout's `user.name` and `user.email`,
so a different identity configured in the tap is never published.
The separate checkout must be clean and on that default branch, with no local
commits that prevent a fast-forward. The script fetches both `origin` branches
and requires them to point to the same commit before modifying casks. It checks
again before pulling and implements the pull as a fetch followed by a
fast-forward, so it can verify the published commit and refuse to overwrite
ignored files. It never touches uncommitted work in the separate checkout,
creates merge commits, or force-pushes.

When the script is invoked directly from the installed tap, the tap is not
reset; it must then be clean, on `origin`'s default branch, and at the same
commit as `origin`.

Dry runs skip these Git publishing and synchronization checks, so they can also
inspect a tap with local changes. After a successful normal run, other machines
can run `brew update && brew upgrade` to receive the published versions; no
manual commit or push is needed.

Run `bash tests/update-casks.sh` to test the updater using temporary local Git
repositories and a mock Homebrew; it does not modify the installed tap.

### Troubleshooting

- If `brew livecheck` fails, reports an error, or returns an empty or invalid result for a cask, the script reports the problem and continues with the next one; the run exits non-zero and does not pull a separate checkout.
- If Homebrew refuses to load casks from this tap as untrusted, review the tap and run `brew trust --tap ceenobyte/personal-casks` once.
- If `brew bump-cask-pr` or a cask audit fails (e.g. the download URL changed in an unexpected way), the affected cask is reported as failed and the script exits with a non-zero status. Other successful bumps are still committed and pushed; failed files remain local for review, and a separate checkout is not pulled.
- If Git reports local changes, a different branch, a local/remote commit mismatch, or an incompatible history in the separate checkout (or in the tap when invoked directly from it), resolve that state separately before retrying. The script stops before modifying any casks in these cases.
- If `origin/HEAD` is missing, verify the remote and run `git remote set-head origin --auto` in the tap checkout.
- If fetching, committing, pushing, or pulling fails, the script reports an error and exits non-zero. Cask changes or an already-created commit remain in the installed tap; a successfully pushed commit remains on `origin`. Inspect the state before retrying. A failed push prints the explicit retry command.
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