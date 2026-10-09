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
  err "Homebrew akzeptiert Cask-Dateien fuer livecheck und bump-cask-pr nur innerhalb eines installierten Taps."
  err "Fuehre das Skript stattdessen im Tap-Checkout aus: ${tap_repo_real}"
  err "Beispiel: cd \"${tap_repo_real}\" && ./scripts/update-casks.command --dry-run"
  exit 1
fi

command -v jq   >/dev/null 2>&1 || { err "jq wurde nicht gefunden. Installiere es mit: brew install jq"; exit 1; }

cask_files=()
while IFS= read -r -d '' file; do
  if grep -qE '^[[:space:]]*cask[[:space:]]+"[^"]+"[[:space:]]+do' "${file}"; then
    cask_files+=("${file}")
  fi
done < <(find "${repo_root}" -type f -name '*.rb' ! -path '*/.git/*' -print0)

if [[ ${#cask_files[@]} -eq 0 ]]; then
  warn "Keine Cask-Dateien (*.rb mit 'cask \"...\" do') unter ${repo_root} gefunden."
  exit 0
fi

log "${#cask_files[@]} Cask-Datei(en) gefunden."
${dry_run} && log "Dry-Run-Modus: es werden keine Dateien veraendert."

updated=()
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

  log "Pruefe ${token} (${rel_path}) ..."

  if ! livecheck_json="$(brew livecheck "${file}" --cask --json --quiet 2>/tmp/livecheck-error.$$)"; then
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
    if ! brew bump-cask-pr "${file}" --version="${latest_version}" --write-only --no-browse --no-audit; then
      warn "Automatischer Versions-Bump fuer ${token} ist fehlgeschlagen (z. B. URL/SHA-256 pruefen)."
      failed+=("${token}")
      continue
    fi

    if ! brew audit --cask --online --except=github_prerelease_version,min_os "ceenobyte/personal-casks/${token}"; then
      warn "Gezieltes Online-Audit fuer ${token} ist fehlgeschlagen."
      failed+=("${token}")
      continue
    fi
  elif ! brew bump-cask-pr "${file}" --version="${latest_version}" --write-only --no-browse; then
    warn "Automatischer Versions-Bump fuer ${token} ist fehlgeschlagen (z. B. URL/SHA-256 pruefen)."
    failed+=("${token}")
    continue
  fi

  updated+=("${token} -> ${latest_version}")
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
  log "Bitte die Aenderungen pruefen (git diff) und committen/pushen,"
  log "damit 'brew update' und 'brew upgrade' sie auf anderen Rechnern uebernehmen."
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  exit 1
fi
