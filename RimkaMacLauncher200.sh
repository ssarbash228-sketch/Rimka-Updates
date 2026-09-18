#!/bin/bash
set -u

launcher_version='1.0.200.0'
root="$HOME/Library/Application Support/Rimka"
current="$root/Current/Rimka.app"
rollback="$root/Rollback/Rimka.app"
work="$root/UpdateWork"
logs="$HOME/Library/Logs/Rimka"
log="$logs/launcher-update.log"
primary='https://raw.githubusercontent.com/ssarbash228-sketch/Rimka-Updates/main/version.json'
secondary='https://www.dropbox.com/scl/fi/wap1jy3sb2otc6j7i5olb/version.json?rlkey=90krkqa9zj1ig51rw2wgnkmdt&raw=1'

mkdir -p "$logs" "$root"
write_log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$log"; }
fail() {
  write_log "FAILURE category=$1 detail=$2"
  /usr/bin/osascript -e "display dialog \"Римка: $2\" buttons {\"OK\"} default button \"OK\" with icon stop" >/dev/null 2>&1 || true
  exit 1
}
json_value() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8-sig') as stream:
    value = json.load(stream)
for part in sys.argv[2].split('.'):
    value = value[part]
print(value)
PY
}
valid_manifest() {
  /usr/bin/python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8-sig') as stream:
    value = json.load(stream)
assert isinstance(value.get('version'), str) and value['version']
assert isinstance(value.get('buildId'), str) and value['buildId']
mac = value.get('platforms', {}).get('macos', {})
for key in ('version', 'buildId', 'packageUrl', 'size', 'sha256'):
    assert mac.get(key) not in (None, '')
assert isinstance(mac['size'], int) and mac['size'] > 0
assert len(mac['sha256']) == 64
PY
}

write_log "LAUNCHER_VERSION=$launcher_version ENTRY_PATH=$0"
mkdir -p "$work"
manifest="$work/version.json"
manifest_source=''
if /usr/bin/curl --fail --silent --show-error --location --connect-timeout 8 --max-time 25 "$primary?mac200=$(date +%s)" -o "$manifest" && valid_manifest "$manifest"; then
  manifest_source='GitHub'
  write_log 'PrimaryManifestResult=PASS SecondaryManifestResult=SKIPPED'
else
  write_log 'PRIMARY_MANIFEST_FAIL'
  if /usr/bin/curl --fail --silent --show-error --location --connect-timeout 8 --max-time 25 "$secondary&mac200=$(date +%s)" -o "$manifest" && valid_manifest "$manifest"; then
    manifest_source='Dropbox'
    write_log 'SecondaryManifestResult=PASS'
  else
    fail 'MANIFEST_UNAVAILABLE' 'не удалось получить сведения об обновлении.'
  fi
fi

remote_version=$(json_value "$manifest" platforms.macos.version) || fail 'MANIFEST_INVALID' 'manifest содержит неверную версию macOS.'
remote_build=$(json_value "$manifest" platforms.macos.buildId) || fail 'MANIFEST_INVALID' 'manifest не содержит macOS Build ID.'
asset_url=$(json_value "$manifest" platforms.macos.packageUrl) || fail 'MANIFEST_INVALID' 'manifest не содержит macOS package URL.'
asset_size=$(json_value "$manifest" platforms.macos.size) || fail 'MANIFEST_INVALID' 'manifest не содержит macOS package size.'
asset_sha=$(json_value "$manifest" platforms.macos.sha256 | tr '[:upper:]' '[:lower:]') || fail 'MANIFEST_INVALID' 'manifest не содержит macOS SHA.'
installed_version='<missing>'
installed_build='<missing>'
identity=''
if [ -d "$current" ]; then
  identity=$(find "$current/Contents" -name RimkaBuildIdentity.json -type f -print -quit 2>/dev/null || true)
  if [ -n "$identity" ]; then
    installed_version=$(json_value "$identity" version 2>/dev/null || printf '<invalid>')
    installed_build=$(json_value "$identity" buildId 2>/dev/null || printf '<invalid>')
  fi
fi
write_log "INSTALLED_VERSION=$installed_version REMOTE_VERSION=$remote_version BUILD_ID=$remote_build MANIFEST_SOURCE=$manifest_source"

if [ "$installed_version" != "$remote_version" ] || [ "$installed_build" != "$remote_build" ]; then
  available_kb=$(df -Pk "$root" | awk 'NR==2 {print $4}')
  required_kb=$((asset_size / 1024 * 3 + 1048576))
  [ "$available_kb" -ge "$required_kb" ] || fail 'INSUFFICIENT_DISK' 'недостаточно места для обновления.'

  archive="$work/Rimka-macOS-latest.zip"
  /usr/bin/curl --fail --show-error --location --connect-timeout 10 --retry 2 "$asset_url" -o "$archive" || fail 'DOWNLOAD_FAIL' 'не удалось скачать обновление.'
  actual_size=$(stat -f '%z' "$archive")
  [ "$actual_size" = "$asset_size" ] || fail 'DOWNLOAD_FAIL' 'размер загруженного обновления не совпал.'
  actual_sha=$(/usr/bin/shasum -a 256 "$archive" | awk '{print $1}')
  [ "$actual_sha" = "$asset_sha" ] || fail 'SHA_FAIL' 'контрольная сумма обновления не совпала.'
  write_log "DOWNLOAD=PASS SIZE=$actual_size SHA256=$actual_sha"

  stage="$work/stage"
  /bin/rm -rf "$stage"
  /bin/mkdir -p "$stage"
  /usr/bin/ditto -x -k "$archive" "$stage" || fail 'STAGING_FAIL' 'не удалось распаковать обновление.'
  staged_app=$(find "$stage" -maxdepth 3 -type d -name Rimka.app -print -quit)
  [ -n "$staged_app" ] || fail 'STAGING_FAIL' 'в архиве отсутствует Rimka.app.'
  /usr/bin/codesign --verify --deep --strict "$staged_app" || fail 'STAGING_FAIL' 'подпись приложения не прошла проверку.'
  staged_identity=$(find "$staged_app/Contents" -name RimkaBuildIdentity.json -type f -print -quit 2>/dev/null || true)
  [ -n "$staged_identity" ] || fail 'STAGING_FAIL' 'в приложении отсутствует Build ID.'
  [ "$(json_value "$staged_identity" version)" = "$remote_version" ] || fail 'STAGING_FAIL' 'версия приложения не совпадает с manifest.'
  [ "$(json_value "$staged_identity" buildId)" = "$remote_build" ] || fail 'STAGING_FAIL' 'Build ID приложения не совпадает с manifest.'

  /bin/rm -rf "$root/Rollback"
  /bin/mkdir -p "$root/Rollback" "$root/Current"
  if [ -d "$current" ]; then
    /bin/mv "$current" "$rollback" || fail 'INSTALL_FAIL' 'не удалось сохранить предыдущую версию.'
  fi
  /usr/bin/ditto "$staged_app" "$current" || {
    [ -d "$rollback" ] && /bin/mv "$rollback" "$current" 2>/dev/null || true
    fail 'INSTALL_FAIL' 'не удалось установить новую версию.'
  }
  write_log "INSTALL=PASS VERSION=$remote_version BUILD_ID=$remote_build"
else
  write_log "UP_TO_DATE VERSION=$installed_version BUILD_ID=$installed_build"
fi

plist="$current/Contents/Info.plist"
bundle_exec=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)
case "$bundle_exec" in ''|*/*) fail 'CLIENT_LAUNCH_FAIL' 'не найден исполняемый файл Римки.' ;; esac
client="$current/Contents/MacOS/$bundle_exec"
[ -x "$client" ] || fail 'CLIENT_LAUNCH_FAIL' 'исполняемый файл Римки недоступен.'
runtime_log="$logs/Rimka_$(date '+%Y%m%d_%H%M%S').log"
nohup "$client" -autoclient -address 95.31.186.225 -port 17779 -playerName 'Сергей Mac' -avatar 1 -voice-photon -voice-mode 2d -voice-channel rimka-voice-recovery-001 -voice-transmit -logFile "$runtime_log" >"$logs/client.stdout.log" 2>&1 </dev/null &
client_pid=$!
sleep 2
kill -0 "$client_pid" 2>/dev/null || fail 'CLIENT_LAUNCH_FAIL' 'клиент закрылся сразу после запуска.'
write_log "CLIENT_LAUNCH=PASS PID=$client_pid VERSION=$remote_version BUILD_ID=$remote_build LOG=$runtime_log"
exit 0
