#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
real_git="$(command -v git)"
real_find="$(command -v find)"
command -v jq >/dev/null 2>&1 || { printf 'jq is required\n' >&2; exit 1; }

test_root="$(mktemp -d "${TMPDIR:-/tmp}/cask-updater-tests.XXXXXXXX")"
test_root="$(cd "${test_root}" && pwd -P)"
trap 'rm -rf "${test_root}"' EXIT
mock_bin="${test_root}/bin"
mkdir -p "${mock_bin}"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Updater Test" GIT_AUTHOR_EMAIL="updater@example.invalid"
export GIT_COMMITTER_NAME="Updater Test" GIT_COMMITTER_EMAIL="updater@example.invalid"

cat >"${mock_bin}/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_GIT_LOG}"
if [[ "${MOCK_PUSH_FAIL}" == true && " $* " == *" push origin "* ]]; then
  printf 'Simulated push failure\n' >&2
  exit 1
fi
exec "${REAL_GIT}" "$@"
GIT

cat >"${mock_bin}/find" <<'FIND'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_FIND_FAIL}" == true ]]; then
  printf 'Simulated cask discovery failure\n' >&2
  exit 1
fi
exec "${REAL_FIND}" "$@"
FIND

cat >"${mock_bin}/brew" <<'BREW'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--repository" ]]; then
  printf '%s\n' "${MOCK_BREW_ROOT}"
  exit 0
fi

if [[ "$(pwd -P)" != "${MOCK_TAP_REPO}" ]]; then
  printf 'Homebrew was not run in the tap checkout\n' >&2
  exit 1
fi
token="${2##*/}"
printf '%s %s\n' "$1" "${token}" >>"${MOCK_BREW_LOG}"
case "$1" in
  livecheck)
    case "${MOCK_LIVECHECK}:${token}" in
      current:*) printf '[{"version":{"outdated":false}}]\n' ;;
      empty:bad) printf '[]\n' ;;
      error:bad) printf '[{"status":"error","messages":["Simulated livecheck error"]}]\n' ;;
      exit-error:bad) printf 'Simulated livecheck failure\n' >&2; exit 1 ;;
      malformed:bad) printf '[{"version":{}}]\n' ;;
      missing-version:bad) printf '[{"version":{"outdated":true}}]\n' ;;
      skipped:bad) printf '[{"status":"skipped","messages":["Not checked"]}]\n' ;;
      disabled:bad) printf '[{"status":"disabled"}]\n' ;;
      *) printf '[{"version":{"outdated":true,"latest":"2.0"}}]\n' ;;
    esac
    ;;
  bump-cask-pr)
    printf 'cask "%s" do\n  version "2.0"\nend\n' "${token}" >"Casks/${token}.rb"
    if [[ "${MOCK_DIRTY_SOURCE}" == true ]]; then
      printf 'User work during update\n' >"${MOCK_SOURCE_REPO}/during-update.txt"
    fi
    if [[ "${MOCK_BAD_FAIL}" == true && "${token}" == "bad" ]]; then
      printf 'Simulated bump failure\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'Unexpected Homebrew command: %s\n' "$1" >&2
    exit 1
    ;;
esac
BREW
chmod +x "${mock_bin}/git" "${mock_bin}/find" "${mock_bin}/brew"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [[ -f "${output:-}" ]]; then
    sed 's/^/  /' "${output}" >&2
  fi
  exit 1
}

assert_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

make_fixture() {
  case_dir="${test_root}/$1"
  seed="${case_dir}/seed"
  remote="${case_dir}/origin.git"
  source_repo="${case_dir}/project checkout"
  brew_root="${case_dir}/Homebrew installation"
  tap_repo="${brew_root}/Library/Taps/ceenobyte/homebrew-personal-casks"
  git_log="${case_dir}/git.log"
  brew_log="${case_dir}/brew.log"
  output="${case_dir}/output"
  mock_livecheck=outdated
  mock_bad_fail=false
  mock_push_fail=false
  mock_find_fail=false
  mock_dirty_source=false

  mkdir -p "${seed}/Casks" "${seed}/scripts" "$(dirname "${tap_repo}")"
  "${real_git}" -c init.defaultBranch=main init -q --bare "${remote}"
  "${real_git}" -c init.defaultBranch=main init -q "${seed}"
  for token in good bad; do
    printf 'cask "%s" do\n  version "1.0"\nend\n' "${token}" >"${seed}/Casks/${token}.rb"
  done
  : >"${seed}/Casks/.keep"
  cp "${project_root}/scripts/update-casks.command" "${seed}/scripts/update-casks.command"
  "${real_git}" -C "${seed}" add Casks scripts
  "${real_git}" -C "${seed}" commit -q -m "Initial fixture" \
    -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
  "${real_git}" -C "${seed}" remote add origin "${remote}"
  "${real_git}" -C "${seed}" push -q -u origin main
  "${real_git}" clone -q "${remote}" "${source_repo}"
  "${real_git}" clone -q "${remote}" "${tap_repo}"
  initial_head="$("${real_git}" -C "${tap_repo}" rev-parse HEAD)"
  run_script="${source_repo}/scripts/update-casks.command"
}

run_updater() {
  : >"${git_log}"
  : >"${brew_log}"
  (
    cd "${case_dir}" || exit 1
    PATH="${mock_bin}:${PATH}" \
      REAL_GIT="${real_git}" \
      REAL_FIND="${real_find}" \
      MOCK_GIT_LOG="${git_log}" \
      MOCK_BREW_LOG="${brew_log}" \
      MOCK_BREW_ROOT="${brew_root}" \
      MOCK_TAP_REPO="${tap_repo}" \
      MOCK_SOURCE_REPO="${source_repo}" \
      MOCK_LIVECHECK="${mock_livecheck}" \
      MOCK_BAD_FAIL="${mock_bad_fail}" \
      MOCK_PUSH_FAIL="${mock_push_fail}" \
      MOCK_FIND_FAIL="${mock_find_fail}" \
      MOCK_DIRTY_SOURCE="${mock_dirty_source}" \
      "${run_script}" "$@"
  ) >"${output}" 2>&1
}

expect_success() {
  if ! run_updater "$@"; then
    fail "updater unexpectedly failed"
  fi
}

expect_failure() {
  if run_updater "$@"; then
    fail "updater unexpectedly succeeded"
  fi
}

assert_no_pull() {
  if grep -Eq ' (pull|merge)( |$)' "${git_log}"; then
    fail "the source checkout was unexpectedly updated"
  fi
}

make_fixture success
expect_success
tap_head="$("${real_git}" -C "${tap_repo}" rev-parse HEAD)"
[[ "${tap_head}" != "${initial_head}" ]] || fail "no update commit was created"
assert_equal "$("${real_git}" --git-dir="${remote}" rev-parse refs/heads/main)" "${tap_head}" "pushed commit"
assert_equal "$("${real_git}" -C "${source_repo}" rev-parse HEAD)" "${tap_head}" "pulled commit"
assert_equal "$("${real_git}" -C "${source_repo}" rev-parse origin/main)" "${tap_head}" "tracking branch"
assert_equal "$("${real_git}" -C "${tap_repo}" diff-tree --no-commit-id --name-only -r HEAD)" \
  "$(printf 'Casks/bad.rb\nCasks/good.rb')" "committed files"
grep -Fq 'version "2.0"' "${source_repo}/Casks/good.rb" || fail "updated cask missing from source checkout"
printf 'PASS: updates are committed, pushed, and pulled\n'

make_fixture dry-run
printf '# Local tap work\n' >>"${tap_repo}/Casks/good.rb"
printf '# Local source work\n' >>"${source_repo}/Casks/good.rb"
cp "${tap_repo}/Casks/good.rb" "${case_dir}/tap-before"
cp "${source_repo}/Casks/good.rb" "${case_dir}/source-before"
expect_success --dry-run
[[ ! -s "${git_log}" ]] || fail "dry run invoked Git"
! grep -q '^bump-cask-pr ' "${brew_log}" || fail "dry run modified a cask"
cmp -s "${case_dir}/tap-before" "${tap_repo}/Casks/good.rb" || fail "dry run changed the tap"
cmp -s "${case_dir}/source-before" "${source_repo}/Casks/good.rb" || fail "dry run changed the source checkout"
printf 'PASS: dry run leaves both dirty checkouts untouched\n'

make_fixture dirty-source
dirty_file="${source_repo}/Casks/good.rb"
printf '# Preserve user work\n' >>"${dirty_file}"
cp "${dirty_file}" "${case_dir}/before"
expect_failure
[[ ! -s "${brew_log}" ]] || fail "Homebrew ran despite a dirty source checkout"
cmp -s "${case_dir}/before" "${dirty_file}" || fail "local changes were altered"
assert_equal "$("${real_git}" -C "${tap_repo}" rev-parse HEAD)" "${initial_head}" "tap HEAD"
printf 'PASS: a dirty source checkout is rejected before cask updates\n'

make_fixture disposable-tap
printf 'Upstream change\n' >"${source_repo}/upstream.txt"
"${real_git}" -C "${source_repo}" add upstream.txt
"${real_git}" -C "${source_repo}" commit -q -m "Upstream change" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
"${real_git}" -C "${source_repo}" push -q origin HEAD:main
upstream_head="$("${real_git}" -C "${source_repo}" rev-parse HEAD)"
printf 'Stale tap commit\n' >"${tap_repo}/stale.txt"
"${real_git}" -C "${tap_repo}" add stale.txt
"${real_git}" -C "${tap_repo}" commit -q -m "Stale tap commit" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
printf '# Stale tap edit\n' >>"${tap_repo}/Casks/bad.rb"
printf 'Untracked\n' >"${tap_repo}/untracked.txt"
mkdir -p "${tap_repo}/tmp" && printf 'Keep\n' >"${tap_repo}/tmp/keep.txt"
"${real_git}" -C "${tap_repo}" checkout -q --detach
mock_livecheck=current
expect_success
assert_equal "$("${real_git}" -C "${tap_repo}" symbolic-ref HEAD)" "refs/heads/main" "tap branch"
assert_equal "$("${real_git}" -C "${tap_repo}" rev-parse HEAD)" "${upstream_head}" "reset tap HEAD"
assert_equal "$("${real_git}" -C "${tap_repo}" status --porcelain -- . ':!tmp')" "" "reset tap status"
[[ -f "${tap_repo}/tmp/keep.txt" ]] || fail "tap tmp directory was cleaned"
printf 'PASS: a stale, dirty, or detached tap is reset to origin\n'

make_fixture source-ahead
printf 'Local commit\n' >"${source_repo}/local.txt"
"${real_git}" -C "${source_repo}" add local.txt
"${real_git}" -C "${source_repo}" commit -q -m "Local work" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
source_head="$("${real_git}" -C "${source_repo}" rev-parse HEAD)"
expect_failure
[[ ! -s "${brew_log}" ]] || fail "Homebrew ran with an incompatible source history"
assert_equal "$("${real_git}" -C "${source_repo}" rev-parse HEAD)" "${source_head}" "local commit"
printf 'PASS: local commits that cannot be fast-forwarded are preserved\n'

make_fixture discovery-failure
mock_find_fail=true
expect_failure
[[ ! -s "${brew_log}" ]] || fail "Homebrew ran after cask discovery failed"
assert_equal "$("${real_git}" -C "${source_repo}" rev-parse HEAD)" "${initial_head}" "source after discovery failure"
assert_no_pull
printf 'PASS: cask discovery failures prevent updates and pulls\n'

make_fixture partial-failure
mock_bad_fail=true
expect_failure
tap_head="$("${real_git}" -C "${tap_repo}" rev-parse HEAD)"
[[ "${tap_head}" != "${initial_head}" ]] || fail "successful cask was not committed"
assert_equal "$("${real_git}" --git-dir="${remote}" rev-parse refs/heads/main)" "${tap_head}" "partial push"
assert_equal "$("${real_git}" -C "${source_repo}" rev-parse HEAD)" "${initial_head}" "source after failure"
assert_equal "$("${real_git}" -C "${tap_repo}" diff-tree --no-commit-id --name-only -r HEAD)" \
  "Casks/good.rb" "successful cask commit"
assert_equal "$("${real_git}" -C "${tap_repo}" diff --name-only)" "Casks/bad.rb" "failed cask changes"
assert_no_pull
printf 'PASS: partial failure publishes only successful casks without pulling\n'

for response in empty error exit-error malformed missing-version; do
  make_fixture "livecheck-${response}"
  mock_livecheck="${response}"
  expect_failure
  tap_head="$("${real_git}" -C "${tap_repo}" rev-parse HEAD)"
  [[ "${tap_head}" != "${initial_head}" ]] || fail "successful cask was not committed"
  assert_equal "$("${real_git}" --git-dir="${remote}" rev-parse refs/heads/main)" "${tap_head}" "partial push"
  assert_equal "$("${real_git}" -C "${source_repo}" rev-parse HEAD)" "${initial_head}" "source after livecheck failure"
  assert_no_pull
done
printf 'PASS: invalid or failed livecheck results prevent the pull\n'

for response in skipped disabled; do
  make_fixture "livecheck-${response}"
  mock_livecheck="${response}"
  expect_success
  assert_equal "$("${real_git}" -C "${source_repo}" rev-parse HEAD)" \
    "$("${real_git}" -C "${tap_repo}" rev-parse HEAD)" "source after skipped cask"
  grep -Fq 'Skipped: bad' "${output}" || fail "skipped cask was not reported"
done
printf 'PASS: skipped casks do not prevent successful updates\n'

make_fixture push-failure
mock_push_fail=true
expect_failure
[[ "$("${real_git}" -C "${tap_repo}" rev-parse HEAD)" != "${initial_head}" ]] || fail "update commit missing"
assert_equal "$("${real_git}" --git-dir="${remote}" rev-parse refs/heads/main)" "${initial_head}" "failed push"
assert_equal "$("${real_git}" -C "${source_repo}" rev-parse HEAD)" "${initial_head}" "source after failed push"
assert_no_pull
printf 'PASS: failed pushes do not update the source checkout\n'

make_fixture source-changed-during-update
mock_dirty_source=true
expect_failure
[[ -f "${source_repo}/during-update.txt" ]] || fail "concurrent source changes were lost"
assert_equal "$("${real_git}" -C "${source_repo}" rev-parse HEAD)" "${initial_head}" "source after concurrent change"
assert_no_pull
printf 'PASS: concurrent source changes prevent the pull\n'

make_fixture different-origins
"${real_git}" clone -q --bare "${remote}" "${case_dir}/other-origin.git"
"${real_git}" -C "${source_repo}" remote set-url origin "${case_dir}/other-origin.git"
expect_failure
assert_equal "$("${real_git}" -C "${source_repo}" rev-parse HEAD)" "${initial_head}" "source with different origin"
assert_no_pull
printf 'PASS: a remote missing the published commit is not pulled\n'

make_fixture already-current
printf '# Previously published update\n' >>"${tap_repo}/Casks/good.rb"
"${real_git}" -C "${tap_repo}" add Casks/good.rb
"${real_git}" -C "${tap_repo}" commit -q -m "Earlier update" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
"${real_git}" -C "${tap_repo}" push -q origin HEAD:main
tap_head="$("${real_git}" -C "${tap_repo}" rev-parse HEAD)"
mock_livecheck=current
expect_success
assert_equal "$("${real_git}" -C "${tap_repo}" rev-parse HEAD)" "${tap_head}" "unchanged tap HEAD"
assert_equal "$("${real_git}" -C "${source_repo}" rev-parse HEAD)" "${tap_head}" "caught-up source HEAD"
! grep -q '^bump-cask-pr ' "${brew_log}" || fail "current casks were bumped"
printf 'PASS: a successful run catches up a behind checkout without a new bump\n'

make_fixture no-casks
"${real_git}" -C "${tap_repo}" rm -q Casks/bad.rb Casks/good.rb
"${real_git}" -C "${tap_repo}" commit -q -m "Remove casks" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
"${real_git}" -C "${tap_repo}" push -q origin HEAD:main
tap_head="$("${real_git}" -C "${tap_repo}" rev-parse HEAD)"
expect_success
assert_equal "$("${real_git}" -C "${source_repo}" rev-parse HEAD)" "${tap_head}" "source without casks"
[[ ! -s "${brew_log}" ]] || fail "Homebrew checked a nonexistent cask"
printf 'PASS: a successful run catches up even when the tap has no casks\n'

make_fixture ignored-file
printf 'Casks/new.rb\n' >>"${source_repo}/.git/info/exclude"
printf 'Local ignored data\n' >"${source_repo}/Casks/new.rb"
printf 'cask "new" do\n  version "1.0"\nend\n' >"${tap_repo}/Casks/new.rb"
"${real_git}" -C "${tap_repo}" add Casks/new.rb
"${real_git}" -C "${tap_repo}" commit -q -m "Add cask" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
"${real_git}" -C "${tap_repo}" push -q origin HEAD:main
mock_livecheck=current
expect_failure
assert_equal "$(cat "${source_repo}/Casks/new.rb")" "Local ignored data" "ignored file"
assert_equal "$("${real_git}" -C "${source_repo}" rev-parse HEAD)" "${initial_head}" "source with ignored file"
printf 'PASS: ignored files are not overwritten by the pull\n'

make_fixture installed-tap
run_script="${tap_repo}/scripts/update-casks.command"
expect_success
tap_head="$("${real_git}" -C "${tap_repo}" rev-parse HEAD)"
[[ "${tap_head}" != "${initial_head}" ]] || fail "direct tap invocation did not commit"
assert_equal "$("${real_git}" --git-dir="${remote}" rev-parse refs/heads/main)" "${tap_head}" "direct tap push"
assert_equal "$("${real_git}" -C "${source_repo}" rev-parse HEAD)" "${initial_head}" "unrelated checkout"
assert_no_pull
printf 'PASS: invoking the installed tap does not pull another checkout\n'
