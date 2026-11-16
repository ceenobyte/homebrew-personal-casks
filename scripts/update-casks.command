#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

dry_run=false
for arg in "$@"; do
  case "${arg}" in
    -n|--dry-run)
      dry_run=true
      ;;
    -h|--help)
      printf 'Verwendung: %s [--dry-run]\n' "$(basename "$0")"
      printf '  --dry-run  Nur anzeigen, welche Casks aktualisiert wuerden.\n'
      printf '  Ohne --dry-run werden erfolgreiche Updates committet und gepusht.\n'
      exit 0
      ;;
    *)
      printf 'Unbekannte Option: %s\n' "${arg}" >&2
      exit 1
      ;;
  esac
done

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'Warnung: %s\n' "$*" >&2; }
err()  { printf 'Fehler: %s\n' "$*" >&2; }

command -v brew >/dev/null 2>&1 || { err "brew wurde nicht gefunden. Siehe https://brew.sh"; exit 1; }

tap_repo="$(brew --repository)/Library/Taps/ceenobyte/homebrew-personal-casks"
if [[ ! -d "${tap_repo}/Casks" ]]; then
  err "Der Homebrew-Tap ceenobyte/personal-casks ist nicht installiert."
  err "Installiere ihn mit: brew tap ceenobyte/personal-casks"
  exit 1
fi

repo_root_real="$(cd "${repo_root}" && pwd -P)"
tap_repo_real="$(cd "${tap_repo}" && pwd -P)"
if [[ "${repo_root_real}" != "${tap_repo_real}" ]]; then
  err "Das Skript muss im Homebrew-verwalteten Tap-Checkout ausgefuehrt werden."
  err "Fuehre das Skript stattdessen im Tap-Checkout aus: ${tap_repo_real}"
  err "Beispiel: cd \"${tap_repo_real}\" && ./scripts/update-casks.command --dry-run"
  exit 1
fi

command -v jq   >/dev/null 2>&1 || { err "jq wurde nicht gefunden. Installiere es mit: brew install jq"; exit 1; }

if ! ${dry_run}; then
  command -v git >/dev/null 2>&1 || { err "git wurde nicht gefunden."; exit 1; }

  git_root="$(git -C "${repo_root}" rev-parse --show-toplevel)"
  if [[ "${git_root}" != "${repo_root_real}" ]]; then
    err "Der Tap-Checkout muss ein eigenstaendiges Git-Repository sein."
    exit 1
  fi

  git_status="$(git -C "${repo_root}" status --porcelain --untracked-files=normal -- . ':!tmp' ':!tmp/**')"
  if [[ -n "${git_status}" ]]; then
    err "Der Tap-Checkout enthaelt lokale Aenderungen. Bitte zuerst separat committen oder sichern."
    exit 1
  fi

  if ! branch_ref="$(git -C "${repo_root}" symbolic-ref --quiet HEAD)"; then
    err "Der Tap-Checkout befindet sich nicht auf einem Branch (detached HEAD)."
    exit 1
  fi
  if ! remote_head="$(git -C "${repo_root}" symbolic-ref --quiet refs/remotes/origin/HEAD)"; then
    err "Der Standardbranch von origin ist unbekannt. Pruefe: git remote set-head origin --auto"
    exit 1
  fi
  publish_ref="refs/heads/${remote_head#refs/remotes/origin/}"
  if [[ "${branch_ref}" != "${publish_ref}" ]]; then
    err "Automatische Updates sind nur auf dem Standardbranch ${publish_ref#refs/heads/} erlaubt."
    exit 1
  fi

  log "Pruefe den aktuellen Stand von ${remote_head#refs/remotes/} ..."
  if ! git -C "${repo_root}" fetch origin "${publish_ref}:${remote_head}"; then
    err "Der Remote-Stand konnte nicht abgerufen werden. Es werden keine Casks veraendert."
    exit 1
  fi
  head_before="$(git -C "${repo_root}" rev-parse HEAD)"
  remote_commit="$(git -C "${repo_root}" rev-parse "${remote_head}")"
  if [[ "${head_before}" != "${remote_commit}" ]]; then
    err "Lokaler Branch und ${remote_head#refs/remotes/} sind nicht auf demselben Stand."
    err "Bitte zuerst synchronisieren bzw. eigene Commits separat veroeffentlichen."
    exit 1
  fi
fi

cask_files=()
while IFS= read -r -d '' file; do
  if grep -qE '^[[:space:]]*cask[[:space:]]+"[^"]+"[[:space:]]+do' "${file}"; then
    cask_files+=("${file}")
  fi
done < <(find "${repo_root}" \( -name .git -o -path "${repo_root}/tmp" \) -prune -o -type f -name '*.rb' -print0)

if [[ ${#cask_files[@]} -eq 0 ]]; then
  warn "Keine Cask-Dateien (*.rb mit 'cask \"...\" do') unter ${repo_root} gefunden."
  exit 0
fi

log "${#cask_files[@]} Cask-Datei(en) gefunden."
${dry_run} && log "Dry-Run-Modus: keine Dateiaenderungen, kein Git-Fetch, Commit oder Push."

updated=()
updated_files=()
uptodate=()
skipped=()
failed=()

for file in "${cask_files[@]}"; do
  token="$(sed -nE 's/^[[:space:]]*cask[[:space:]]+"([^"]+)".*/\1/p' "${file}" | head -n1)"
  rel_path="${file#"${repo_root}"/}"

  if [[ -z "${token}" ]]; then
    warn "Konnte in ${rel_path} keinen Cask-Token ermitteln, ueberspringe."
    failed+=("${rel_path}")
    continue
  fi

  cask_ref="ceenobyte/personal-casks/${token}"

  log "Pruefe ${token} (${rel_path}) ..."

  if ! livecheck_json="$(brew livecheck "${cask_ref}" --cask --json --quiet 2>/tmp/livecheck-error.$$)"; then
    warn "brew livecheck ist fuer ${token} fehlgeschlagen:"
    sed 's/^/    /' /tmp/livecheck-error.$$ >&2 || true
    rm -f /tmp/livecheck-error.$$
    failed+=("${token}")
    continue
  fi
  rm -f /tmp/livecheck-error.$$

  livecheck_status="$(jq -r '.[0].status // empty' <<<"${livecheck_json}")"
  if [[ "${livecheck_status}" == "skipped" ]]; then
    skip_message="$(jq -r '.[0].messages // [] | join("; ")' <<<"${livecheck_json}")"
    log "${token} wird uebersprungen: ${skip_message}"
    skipped+=("${token}")
    continue
  fi

  if [[ "$(jq 'length' <<<"${livecheck_json}")" -eq 0 ]]; then
    log "${token} ist bereits aktuell."
    uptodate+=("${token}")
    continue
  fi

  if [[ "$(jq -r '.[0].version.outdated // false' <<<"${livecheck_json}")" != "true" ]]; then
    log "${token} ist bereits aktuell."
    uptodate+=("${token}")
    continue
  fi

  latest_version="$(jq -r '.[0].version.latest // .[0].version // empty' <<<"${livecheck_json}")"

  if [[ -z "${latest_version}" || "${latest_version}" == "null" ]]; then
    warn "Konnte fuer ${token} keine neue Version aus der livecheck-Antwort lesen:"
    printf '%s\n' "${livecheck_json}" | sed 's/^/    /' >&2
    failed+=("${token}")
    continue
  fi

  log "Neue Version fuer ${token} gefunden: ${latest_version}"

  if ${dry_run}; then
    updated+=("${token} -> ${latest_version} (dry-run, nicht geschrieben)")
    continue
  fi

  if [[ "${token}" == "freetube" ]]; then
    if ! brew bump-cask-pr "${cask_ref}" --version="${latest_version}" --write-only --no-browse --no-audit; then
      warn "Automatischer Versions-Bump fuer ${token} ist fehlgeschlagen (z. B. URL/SHA-256 pruefen)."
      failed+=("${token}")
      continue
    fi

    if ! brew audit --cask --online --except=github_prerelease_version,min_os "ceenobyte/personal-casks/${token}"; then
      warn "Gezieltes Online-Audit fuer ${token} ist fehlgeschlagen."
      failed+=("${token}")
      continue
    fi
  elif ! brew bump-cask-pr "${cask_ref}" --version="${latest_version}" --write-only --no-browse; then
    warn "Automatischer Versions-Bump fuer ${token} ist fehlgeschlagen (z. B. URL/SHA-256 pruefen)."
    failed+=("${token}")
    continue
  fi

  updated+=("${token} -> ${latest_version}")
  updated_files+=("${rel_path}")
done

echo
log "Zusammenfassung:"
if [[ ${#updated[@]} -gt 0 ]]; then
  printf '  Aktualisiert:\n'
  printf '    - %s\n' "${updated[@]}"
fi
if [[ ${#uptodate[@]} -gt 0 ]]; then
  printf '  Bereits aktuell: %s\n' "$(IFS=, ; echo "${uptodate[*]}")"
fi
if [[ ${#skipped[@]} -gt 0 ]]; then
  printf '  Uebersprungen: %s\n' "$(IFS=, ; echo "${skipped[*]}")"
fi
if [[ ${#failed[@]} -gt 0 ]]; then
  printf '  Fehlgeschlagen:\n'
  printf '    - %s\n' "${failed[@]}"
fi

if [[ ${#updated[@]} -gt 0 ]] && ! ${dry_run}; then
  echo
  if ! current_branch="$(git -C "${repo_root}" symbolic-ref --quiet HEAD)"; then
    err "Der Tap-Checkout befindet sich jetzt im detached-HEAD-Zustand. Kein automatischer Commit oder Push."
    exit 1
  fi
  current_head="$(git -C "${repo_root}" rev-parse HEAD)"
  if [[ "${current_branch}" != "${branch_ref}" || "${current_head}" != "${head_before}" ]]; then
    err "Branch oder HEAD wurden waehrend des Updates geaendert. Kein automatischer Commit oder Push."
    exit 1
  fi

  changed_files="$(git -C "${repo_root}" diff --name-only HEAD -- "${updated_files[@]}")"
  if [[ -z "${changed_files}" ]]; then
    log "Keine Dateiaenderungen durch die Updates; kein Commit oder Push erforderlich."
  else
    log "Committe erfolgreich aktualisierte Casks ..."
    if ! git -C "${repo_root}" commit --only -m "Bump cask versions" -m "$(printf '%s\n' "${updated[@]}")" -- "${updated_files[@]}"; then
      err "Commit fehlgeschlagen. Die Cask-Aenderungen bleiben lokal zur Pruefung erhalten."
      exit 1
    fi

    log "Pushe Updates nach ${remote_head#refs/remotes/} ..."
    if ! git -C "${repo_root}" push origin "HEAD:${publish_ref}"; then
      err "Push fehlgeschlagen. Der Update-Commit bleibt lokal erhalten."
      err "Nach Pruefung erneut pushen: git -C \"${repo_root}\" push origin \"HEAD:${publish_ref}\""
      exit 1
    fi
    log "Updates veroeffentlicht. Andere Clients koennen sie mit 'brew update' und 'brew upgrade' uebernehmen."
  fi
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  exit 1
fi
