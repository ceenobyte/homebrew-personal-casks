#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_repo="$(cd "${script_dir}/.." && pwd -P)"

dry_run=false
for arg in "$@"; do
  case "${arg}" in
    -n|--dry-run)
      dry_run=true
      ;;
    -h|--help)
      printf 'Usage: %s [--dry-run]\n' "$(basename "$0")"
      printf '  --dry-run  Only show which casks would be updated.\n'
      printf '  Without --dry-run, successful updates are committed and pushed.\n'
      printf '  After success, a separate source checkout is pulled.\n'
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "${arg}" >&2
      exit 1
      ;;
  esac
done

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
err()  { printf 'Error: %s\n' "$*" >&2; }

command -v brew >/dev/null 2>&1 || { err "brew was not found. See https://brew.sh"; exit 1; }

tap_repo="$(brew --repository)/Library/Taps/ceenobyte/homebrew-personal-casks"
if [[ ! -d "${tap_repo}/Casks" ]]; then
  err "The Homebrew tap ceenobyte/personal-casks is not installed."
  err "Install it with: brew tap ceenobyte/personal-casks"
  exit 1
fi

repo_root="$(cd "${tap_repo}" && pwd -P)"
log "Switching to the Homebrew tap checkout: ${repo_root}"
cd "${repo_root}" || { err "The Homebrew tap checkout is not accessible."; exit 1; }

command -v jq   >/dev/null 2>&1 || { err "jq was not found. Install it with: brew install jq"; exit 1; }

if ! ${dry_run}; then
  command -v git >/dev/null 2>&1 || { err "git was not found."; exit 1; }

  git_root="$(git -C "${repo_root}" rev-parse --show-toplevel)"
  if [[ "${git_root}" != "${repo_root}" ]]; then
    err "The tap checkout must be a standalone Git repository."
    exit 1
  fi

  git_status="$(git -C "${repo_root}" status --porcelain --untracked-files=normal -- . ':!tmp' ':!tmp/**')"
  if [[ -n "${git_status}" ]]; then
    err "The tap checkout has local changes. Please commit or stash them first."
    exit 1
  fi

  if ! branch_ref="$(git -C "${repo_root}" symbolic-ref --quiet HEAD)"; then
    err "The tap checkout is not on a branch (detached HEAD)."
    exit 1
  fi
  if ! remote_head="$(git -C "${repo_root}" symbolic-ref --quiet refs/remotes/origin/HEAD)"; then
    err "The default branch for origin is unknown. Check with: git remote set-head origin --auto"
    exit 1
  fi
  publish_ref="refs/heads/${remote_head#refs/remotes/origin/}"
  if [[ "${branch_ref}" != "${publish_ref}" ]]; then
    err "Automatic updates are only allowed on the default branch ${publish_ref#refs/heads/}."
    exit 1
  fi

  if [[ "${source_repo}" != "${repo_root}" ]]; then
    if ! source_git_root="$(git -C "${source_repo}" rev-parse --show-toplevel)"; then
      err "The source checkout is not a Git repository: ${source_repo}"
      exit 1
    fi
    if [[ "${source_git_root}" != "${source_repo}" ]]; then
      err "The source checkout must be a standalone Git repository."
      exit 1
    fi
    source_status="$(git -C "${source_repo}" status --porcelain --untracked-files=normal)"
    if [[ -n "${source_status}" ]]; then
      err "The source checkout has local changes. Please commit or stash them first."
      exit 1
    fi
    if ! source_branch="$(git -C "${source_repo}" symbolic-ref --quiet HEAD)"; then
      err "The source checkout is not on a branch (detached HEAD)."
      exit 1
    fi
    if [[ "${source_branch}" != "${publish_ref}" ]]; then
      err "The source checkout must be on the default branch ${publish_ref#refs/heads/}."
      exit 1
    fi
    source_head="$(git -C "${source_repo}" rev-parse HEAD)"
  fi

  log "Checking the current state of ${remote_head#refs/remotes/} ..."
  if ! git -C "${repo_root}" fetch origin "${publish_ref}:${remote_head}"; then
    err "Could not fetch the remote state. No casks have been changed."
    exit 1
  fi
  head_before="$(git -C "${repo_root}" rev-parse HEAD)"
  remote_commit="$(git -C "${repo_root}" rev-parse "${remote_head}")"
  if [[ "${head_before}" != "${remote_commit}" ]]; then
    err "The local branch and ${remote_head#refs/remotes/} are not at the same commit."
    err "Please synchronize first or publish your local commits separately."
    exit 1
  fi
  published_head="${head_before}"

  if [[ "${source_repo}" != "${repo_root}" ]]; then
    log "Checking the remote state of the source checkout ..."
    if ! git -C "${source_repo}" fetch origin "${publish_ref}:${remote_head}"; then
      err "Could not fetch the source checkout's remote state. No casks have been changed."
      exit 1
    fi
    source_remote_commit="$(git -C "${source_repo}" rev-parse "${remote_head}")"
    if [[ "${source_remote_commit}" != "${head_before}" ]]; then
      err "The tap and source checkout's origin branches point to different commits."
      exit 1
    fi
    if ! git -C "${source_repo}" merge-base --is-ancestor "${source_head}" "${source_remote_commit}"; then
      err "The source checkout cannot be updated with a fast-forward."
      err "Please synchronize local commits or divergent branches separately first."
      exit 1
    fi
  fi
fi

cask_list="$(mktemp "${TMPDIR:-/tmp}/cask-files.XXXXXXXX")" || { err "Could not create the temporary cask list."; exit 1; }
trap 'rm -f "${cask_list}"' EXIT
if ! find "${repo_root}" \( -name .git -o -path "${repo_root}/tmp" \) -prune -o -type f -name '*.rb' -print0 >"${cask_list}"; then
  err "Could not enumerate all cask files."
  exit 1
fi

cask_files=()
while IFS= read -r -d '' file; do
  if grep -qE '^[[:space:]]*cask[[:space:]]+"[^"]+"[[:space:]]+do' "${file}"; then
    cask_files+=("${file}")
  else
    grep_status=$?
    if [[ "${grep_status}" -ne 1 ]]; then
      err "Could not check the file for a cask definition: ${file}"
      exit 1
    fi
  fi
done <"${cask_list}"
rm -f "${cask_list}"
trap - EXIT

if [[ ${#cask_files[@]} -eq 0 ]]; then
  warn "No cask files (*.rb containing 'cask \"...\" do') found under ${repo_root}."
else
  log "Found ${#cask_files[@]} cask file(s)."
fi

${dry_run} && log "Dry-run mode: no file changes, Git fetch, commit, push, or pull."

updated=()
updated_files=()
uptodate=()
skipped=()
failed=()

# Bash 3.2 treats an empty array as unset when expanding it with set -u.
for file in "${cask_files[@]+"${cask_files[@]}"}"; do
  token="$(sed -nE 's/^[[:space:]]*cask[[:space:]]+"([^"]+)".*/\1/p' "${file}" | head -n1)"
  rel_path="${file#"${repo_root}"/}"

  if [[ -z "${token}" ]]; then
    warn "Could not determine the cask token in ${rel_path}; skipping."
    failed+=("${rel_path}")
    continue
  fi

  cask_ref="ceenobyte/personal-casks/${token}"

  log "Checking ${token} (${rel_path}) ..."

  if ! livecheck_json="$(brew livecheck "${cask_ref}" --cask --json --quiet 2>/tmp/livecheck-error.$$)"; then
    warn "brew livecheck failed for ${token}:"
    sed 's/^/    /' /tmp/livecheck-error.$$ >&2 || true
    rm -f /tmp/livecheck-error.$$
    failed+=("${token}")
    continue
  fi
  rm -f /tmp/livecheck-error.$$

  if ! jq -e 'type == "array" and length == 1 and (.[0] | type == "object")' <<<"${livecheck_json}" >/dev/null; then
    warn "brew livecheck returned an invalid result for ${token}:"
    printf '%s\n' "${livecheck_json}" | sed 's/^/    /' >&2
    failed+=("${token}")
    continue
  fi

  livecheck_status="$(jq -r '.[0].status // empty' <<<"${livecheck_json}")"
  if [[ "${livecheck_status}" == "skipped" ]]; then
    skip_message="$(jq -r '.[0].messages // [] | join("; ")' <<<"${livecheck_json}")"
    log "Skipping ${token}: ${skip_message}"
    skipped+=("${token}")
    continue
  fi
  if [[ "${livecheck_status}" == "error" ]]; then
    livecheck_message="$(jq -r '.[0].messages // [] | join("; ")' <<<"${livecheck_json}")"
    warn "brew livecheck reported an error for ${token}: ${livecheck_message:-no details}"
    failed+=("${token}")
    continue
  fi
  if [[ "${livecheck_status}" == "disabled" || "${livecheck_status}" == "deprecated" || \
        "${livecheck_status}" == "latest" || "${livecheck_status}" == "unversioned" || \
        "${livecheck_status}" == "versioned" ]]; then
    log "Skipping ${token}: ${livecheck_status}"
    skipped+=("${token}")
    continue
  fi
  if [[ -n "${livecheck_status}" ]] || \
     ! jq -e '.[0].version.outdated | type == "boolean"' <<<"${livecheck_json}" >/dev/null; then
    warn "brew livecheck returned an unknown status or no version information for ${token}:"
    printf '%s\n' "${livecheck_json}" | sed 's/^/    /' >&2
    failed+=("${token}")
    continue
  fi
  if [[ "$(jq -r '.[0].version.outdated' <<<"${livecheck_json}")" != "true" ]]; then
    log "${token} is already up to date."
    uptodate+=("${token}")
    continue
  fi

  if ! latest_version="$(jq -er '.[0].version.latest | select(type == "string" and length > 0)' <<<"${livecheck_json}")" || \
     [[ "${latest_version}" == "null" ]]; then
    warn "Could not read a new version for ${token} from the livecheck response:"
    printf '%s\n' "${livecheck_json}" | sed 's/^/    /' >&2
    failed+=("${token}")
    continue
  fi

  log "Found a new version for ${token}: ${latest_version}"

  if ${dry_run}; then
    updated+=("${token} -> ${latest_version} (dry-run, not written)")
    continue
  fi

  if [[ "${token}" == "freetube" ]]; then
    if ! brew bump-cask-pr "${cask_ref}" --version="${latest_version}" --write-only --no-browse --no-audit; then
      warn "Automatic version bump failed for ${token} (e.g. check the URL/SHA-256)."
      failed+=("${token}")
      continue
    fi

    if ! brew audit --cask --online --except=github_prerelease_version,min_os "ceenobyte/personal-casks/${token}"; then
      warn "Targeted online audit failed for ${token}."
      failed+=("${token}")
      continue
    fi
  elif ! brew bump-cask-pr "${cask_ref}" --version="${latest_version}" --write-only --no-browse; then
    warn "Automatic version bump failed for ${token} (e.g. check the URL/SHA-256)."
    failed+=("${token}")
    continue
  fi

  updated+=("${token} -> ${latest_version}")
  updated_files+=("${rel_path}")
done

echo
log "Summary:"
if [[ ${#updated[@]} -gt 0 ]]; then
  printf '  Updated:\n'
  printf '    - %s\n' "${updated[@]}"
fi
if [[ ${#uptodate[@]} -gt 0 ]]; then
  printf '  Already up to date: %s\n' "$(IFS=, ; echo "${uptodate[*]}")"
fi
if [[ ${#skipped[@]} -gt 0 ]]; then
  printf '  Skipped: %s\n' "$(IFS=, ; echo "${skipped[*]}")"
fi
if [[ ${#failed[@]} -gt 0 ]]; then
  printf '  Failed:\n'
  printf '    - %s\n' "${failed[@]}"
fi

if [[ ${#updated[@]} -gt 0 ]] && ! ${dry_run}; then
  echo
  if ! current_branch="$(git -C "${repo_root}" symbolic-ref --quiet HEAD)"; then
    err "The tap checkout is now in a detached HEAD state. No automatic commit or push."
    exit 1
  fi
  current_head="$(git -C "${repo_root}" rev-parse HEAD)"
  if [[ "${current_branch}" != "${branch_ref}" || "${current_head}" != "${head_before}" ]]; then
    err "The branch or HEAD changed during the update. No automatic commit or push."
    exit 1
  fi

  changed_files="$(git -C "${repo_root}" diff --name-only HEAD -- "${updated_files[@]}")"
  if [[ -z "${changed_files}" ]]; then
    log "The updates made no file changes; no commit or push is needed."
  else
    log "Committing successfully updated casks ..."
    if ! git -C "${repo_root}" commit --only -m "Bump cask versions" -m "$(printf '%s\n' "${updated[@]}")" -- "${updated_files[@]}"; then
      err "Commit failed. The cask changes remain local for review."
      exit 1
    fi
    published_head="$(git -C "${repo_root}" rev-parse HEAD)"

    log "Pushing updates to ${remote_head#refs/remotes/} ..."
    if ! git -C "${repo_root}" push origin "${published_head}:${publish_ref}"; then
      err "Push failed. The update commit remains local."
      err "After review, retry with: git -C \"${repo_root}\" push origin \"${published_head}:${publish_ref}\""
      exit 1
    fi
    log "Updates published. Other clients can receive them with 'brew update' and 'brew upgrade'."
  fi
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  exit 1
fi

if ! ${dry_run} && [[ "${source_repo}" != "${repo_root}" ]]; then
  if ! current_branch="$(git -C "${repo_root}" symbolic-ref --quiet HEAD)"; then
    err "The tap checkout is now in a detached HEAD state. No pull will be performed."
    exit 1
  fi
  current_head="$(git -C "${repo_root}" rev-parse HEAD)"
  if [[ "${current_branch}" != "${branch_ref}" || "${current_head}" != "${published_head}" ]]; then
    err "The tap checkout's branch or HEAD changed during the update. No pull will be performed."
    exit 1
  fi

  log "Checking the published state in the source checkout ..."
  if ! git -C "${source_repo}" fetch origin "${publish_ref}:${remote_head}"; then
    err "Could not fetch the source checkout's remote state. No pull will be performed."
    exit 1
  fi
  source_remote_commit="$(git -C "${source_repo}" rev-parse "${remote_head}")"
  if ! git -C "${source_repo}" merge-base --is-ancestor "${published_head}" "${source_remote_commit}"; then
    err "The source checkout's origin branch does not contain the published tap commit. No pull will be performed."
    exit 1
  fi

  if ! current_source_branch="$(git -C "${source_repo}" symbolic-ref --quiet HEAD)"; then
    err "The source checkout is now in a detached HEAD state. No pull will be performed."
    exit 1
  fi
  current_source_head="$(git -C "${source_repo}" rev-parse HEAD)"
  source_status="$(git -C "${source_repo}" status --porcelain --untracked-files=normal)"
  if [[ "${current_source_branch}" != "${source_branch}" || "${current_source_head}" != "${source_head}" || -n "${source_status}" ]]; then
    err "The source checkout's branch, HEAD, or working tree changed during the update. No pull will be performed."
    exit 1
  fi

  log "Updating the source checkout with a fast-forward pull ..."
  if ! git -C "${source_repo}" merge --ff-only --no-autostash --no-overwrite-ignore "${source_remote_commit}"; then
    err "Pull failed. The published updates remain in the tap and on origin."
    exit 1
  fi
  if ! git -C "${source_repo}" merge-base --is-ancestor "${published_head}" HEAD; then
    err "The pull does not contain the published tap commit. Please check origin."
    exit 1
  fi
  log "Source checkout updated: ${source_repo}"
fi
