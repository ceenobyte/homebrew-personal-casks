#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'Warnung: %s\n' "$*" >&2; }
err()  { printf 'Fehler: %s\n' "$*" >&2; }

command -v ruby >/dev/null 2>&1 || { err "ruby wurde nicht gefunden."; exit 1; }

helper="$(mktemp)"
trap 'rm -f "${helper}"' EXIT

cat >"${helper}" <<'RUBY'
path = ARGV.fetch(0)
content = File.read(path)

if content.include?("com.apple.quarantine")
  puts "SKIP_EXISTS"
  exit 0
end

app_names = content.each_line.filter_map do |line|
  match = line.match(/^\s*app\s+"([^"]+)"/)
  match && match[1]
end

if app_names.empty?
  puts "SKIP_NO_APP"
  exit 0
end

commands = app_names.map do |app_name|
  <<~CMD
    system_command "/usr/bin/xattr",
                    args: ["-dr", "com.apple.quarantine", "\#{appdir}/#{app_name}"],
                    sudo: false
  CMD
end

postflight_lines = ["  postflight do\n"]
commands.each do |cmd|
  cmd.each_line { |l| postflight_lines << "    #{l}" }
end
postflight_lines << "  end\n"

lines = content.each_line.to_a
artifact_regex = /^\s*(app|binary|pkg|suite|manpage)\s+"/
last_artifact_index = lines.rindex { |line| line.match?(artifact_regex) }

if last_artifact_index.nil?
  puts "SKIP_NO_APP"
  exit 0
end

before = lines[0..last_artifact_index]
rest = lines[(last_artifact_index + 1)..] || []
rest.shift while rest.first && rest.first.strip.empty?

new_lines = before + ["\n"] + postflight_lines + ["\n"] + rest
File.write(path, new_lines.join)

puts "ADDED:#{app_names.join(',')}"
RUBY

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

added=()
already_present=()
skipped=()
failed=()

for file in "${cask_files[@]}"; do
  rel_path="${file#"${repo_root}"/}"
  token="$(sed -nE 's/^[[:space:]]*cask[[:space:]]+"([^"]+)".*/\1/p' "${file}" | head -n1)"

  if ! result="$(ruby "${helper}" "${file}")"; then
    warn "Verarbeitung von ${rel_path} fehlgeschlagen."
    failed+=("${token:-${rel_path}}")
    continue
  fi

  case "${result}" in
    SKIP_EXISTS)
      log "${token}: postflight-Quarantaene-Entfernung bereits vorhanden."
      already_present+=("${token}")
      ;;
    SKIP_NO_APP)
      log "${token}: kein 'app'-Artefakt gefunden, ueberspringe."
      skipped+=("${token}")
      ;;
    ADDED:*)
      apps="${result#ADDED:}"
      log "${token}: postflight fuer '${apps}' ergaenzt."
      added+=("${token} (${apps})")
      ;;
    *)
      warn "Unerwartete Ausgabe fuer ${token}: ${result}"
      failed+=("${token}")
      ;;
  esac
done

echo
log "Zusammenfassung:"
if [[ ${#added[@]} -gt 0 ]]; then
  printf '  Ergaenzt:\n'
  printf '    - %s\n' "${added[@]}"
fi
if [[ ${#already_present[@]} -gt 0 ]]; then
  printf '  Bereits vorhanden: %s\n' "$(IFS=, ; echo "${already_present[*]}")"
fi
if [[ ${#skipped[@]} -gt 0 ]]; then
  printf '  Uebersprungen (kein app-Artefakt): %s\n' "$(IFS=, ; echo "${skipped[*]}")"
fi
if [[ ${#failed[@]} -gt 0 ]]; then
  printf '  Fehlgeschlagen:\n'
  printf '    - %s\n' "${failed[@]}"
fi

if [[ ${#added[@]} -gt 0 ]]; then
  echo
  log "Bitte die Aenderungen pruefen (git diff) und committen/pushen."
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  exit 1
fi
