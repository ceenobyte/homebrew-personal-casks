# Agent Instructions

## Scope

These instructions apply to the entire repository. Preserve existing user
changes and keep edits focused on the requested task.

## Project

This repository is the `ceenobyte/personal-casks` Homebrew tap. It maintains
casks that are still useful even when upstream Homebrew has disabled them,
and includes a script for checking and bumping cask versions.

- `Casks/*.rb` contains the tap's cask definitions.
- `scripts/update-casks.command` uses Homebrew's `livecheck` and
  `bump-cask-pr` tools to check and write version updates.
- `README.md` is the user-facing source for installation, use, and upkeep.

## Safety and Behavior

- Treat cask files as executable Ruby code. Review tap definitions before
  trusting the tap with `brew trust --tap ceenobyte/personal-casks`.
- Run `scripts/update-casks.command` only from the Homebrew-managed checkout
  of this installed tap. Preserve the script's installed-tap and checkout
  checks.
- Keep `--dry-run` free of file modifications. The updater must not commit or
  push; users review and commit its changes themselves.
- Keep upstream `disable!` or `deprecate!` metadata as comments when the tap
  intentionally keeps a cask active. Preserve the upstream date and reason.
- Let Homebrew calculate updated checksums. Do not guess or copy a checksum
  without verifying it against the corresponding download.
- Never add credentials, private tokens, or other secrets to casks, scripts,
  documentation, or test fixtures.

## Change Workflow

1. Read only the files relevant to the requested change and check the working
   tree before editing.
2. Make the smallest compatible change. Do not reformat unrelated casks or
   overwrite existing user changes.
3. Update `README.md` when installation, updater behavior, requirements, or
   other user-visible procedures change.
4. Do not run commands that install, upgrade, or remove software, or that write
   cask updates, unless the task explicitly calls for that operation.
5. Do not commit, push, reset, or discard changes unless explicitly requested.

## Validation

- For updater script changes, run `bash -n scripts/update-casks.command`.
- For cask changes, use `brew style --cask Casks/<token>.rb` and
  `brew audit --cask Casks/<token>.rb` when Homebrew is available.
- `brew livecheck` can access the network; `brew bump-cask-pr` can modify a
  cask file. Run them only when needed for the task, and review all resulting
  changes.
- Do not install a cask as an automated validation step unless explicitly
  requested.
- Report checks that could not be run and any remaining manual validation.

## Documentation and Style

- Keep user-facing documentation in English, consistent with `README.md`.
- Preserve existing cask formatting and follow Homebrew's Cask Cookbook
  conventions.
- Prefer focused, explicit error messages in shell scripts. Preserve the
  script's existing Bash and macOS compatibility.