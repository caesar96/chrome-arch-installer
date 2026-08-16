#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="${CHROME_APP_DIR:-$HOME/Apps/google-chrome}"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/google-chrome-local-installer"
PACKAGES_URL="https://dl.google.com/linux/chrome/deb/dists/stable/main/binary-amd64/Packages"
INRELEASE_URL="https://dl.google.com/linux/chrome/deb/dists/stable/InRelease"
DEB_BASE_URL="https://dl.google.com/linux/chrome/deb"
GOOGLE_KEY_URL="https://dl.google.com/linux/linux_signing_key.pub"
GOOGLE_KEY_FINGERPRINT="EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796"
WORK_DIR=""

die() {
    printf 'chrome-arch-installer: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR"
}

require_commands() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "Required command is missing: $command_name"
    done
}

chrome_running() {
    local pid stat_line state
    while IFS= read -r pid; do
        [[ -n "$pid" && -r "/proc/$pid/stat" ]] || continue
        stat_line="$(<"/proc/$pid/stat")"
        state="${stat_line#*) }"
        state="${state%% *}"
        [[ "$state" != 'Z' ]] && return 0
    done < <(pgrep -u "$(id -u)" -x chrome || true)
    return 1
}

verify_inrelease() {
    local inrelease_file="$1"
    local key_file keyring_dir status result=1

    key_file="$(mktemp "$CACHE_ROOT/google-key.XXXXXXXX")"
    keyring_dir="$(mktemp -d "$CACHE_ROOT/google-keyring.XXXXXXXX")"

    if curl --fail --location --retry 3 --connect-timeout 15 \
        --silent --show-error --output "$key_file" "$GOOGLE_KEY_URL" && \
        gpg --batch --homedir "$keyring_dir" --import "$key_file" >/dev/null 2>&1 && \
        gpg --batch --homedir "$keyring_dir" --with-colons --fingerprint | \
            awk -F: -v expected="$GOOGLE_KEY_FINGERPRINT" '
                $1 == "fpr" && toupper($10) == expected { found = 1 }
                END { exit found ? 0 : 1 }
            '
    then
        if status="$(gpg --batch --no-auto-key-retrieve --homedir "$keyring_dir" \
            --status-fd=1 --verify "$inrelease_file" 2>/dev/null)"; then
            if awk -v expected="$GOOGLE_KEY_FINGERPRINT" '
                $1 == "[GNUPG:]" && $2 == "VALIDSIG" && toupper($NF) == expected {
                    found = 1
                }
                END { exit found ? 0 : 1 }
            ' <<< "$status"; then
                result=0
            fi
        fi
    fi

    rm -rf -- "$key_file" "$keyring_dir"
    return "$result"
}

verify_packages_metadata() {
    local inrelease_file="$1"
    local metadata_file="$2"
    local expected_sha256 actual_sha256

    expected_sha256="$(awk '
        { gsub(/\r/, "") }
        $1 == "SHA256:" { in_sha256 = 1; next }
        in_sha256 && $3 == "main/binary-amd64/Packages" {
            print $1
            exit
        }
        in_sha256 && $1 ~ /^[A-Z][A-Za-z0-9-]*:$/ { exit }
    ' "$inrelease_file")"
    [[ "$expected_sha256" =~ ^[[:xdigit:]]{64}$ ]] || return 1

    actual_sha256="$(sha256sum "$metadata_file")"
    actual_sha256="${actual_sha256%% *}"
    [[ "$actual_sha256" == "$expected_sha256" ]]
}

package_info() {
    local metadata_file="$1"
    local inrelease_file="${metadata_file}.InRelease"

    curl --fail --location --retry 3 --connect-timeout 15 \
        --silent --show-error --output "$inrelease_file" "$INRELEASE_URL" || {
        rm -f -- "$inrelease_file"
        return 1
    }
    if ! verify_inrelease "$inrelease_file"; then
        printf 'Google repository signature verification failed.\n' >&2
        rm -f -- "$inrelease_file"
        return 1
    fi
    curl --fail --location --retry 3 --connect-timeout 15 \
        --silent --show-error --output "$metadata_file" "$PACKAGES_URL" || {
        rm -f -- "$inrelease_file"
        return 1
    }
    if ! verify_packages_metadata "$inrelease_file" "$metadata_file"; then
        printf 'Google package metadata checksum verification failed.\n' >&2
        rm -f -- "$inrelease_file"
        return 1
    fi
    rm -f -- "$inrelease_file"

    awk -v RS='' -v FS='\n' '
        $1 == "Package: google-chrome-stable" {
            version = filename = sha256 = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^Version: /) {
                    version = $i
                    sub(/^Version: /, "", version)
                } else if ($i ~ /^Filename: /) {
                    filename = $i
                    sub(/^Filename: /, "", filename)
                } else if ($i ~ /^SHA256: /) {
                    sha256 = $i
                    sub(/^SHA256: /, "", sha256)
                }
            }
            if (version != "" && filename != "" && sha256 != "") {
                printf "%s\t%s\t%s\n", version, filename, sha256
                exit
            }
        }
    ' "$metadata_file"
}

version_from_deb() {
    ar p "$1" control.tar.xz | bsdtar -xOf - ./control | \
        awk -F': ' '$1 == "Version" { print $2; exit }'
}

link_system_libraries() {
    local stage_dir="$1"
    local target name
    while IFS=: read -r name target; do
        [[ -e "$target" ]] || die "Required library not found: $target"
        ln -sfn -- "$target" "$stage_dir/$name"
    done <<'LIBRARIES'
libnspr4.so.0d:/usr/lib/libnspr4.so
libplds4.so.0d:/usr/lib/libplds4.so
libplc4.so.0d:/usr/lib/libplc4.so
libssl3.so.1d:/usr/lib/libssl3.so
libnss3.so.1d:/usr/lib/libnss3.so
libsmime3.so.1d:/usr/lib/libsmime3.so
libnssutil3.so.1d:/usr/lib/libnssutil3.so
LIBRARIES
}

usage() {
    printf '%s\n' \
        'Usage: ./install.sh [--deb file.deb]' \
        '       CHROME_APP_DIR=~/Apps/google-chrome ./install.sh'
}

deb_override=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --deb)
            [[ "$#" -ge 2 ]] || die '--deb requires a file.'
            deb_override="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

require_commands curl awk ar bsdtar sha256sum sed tr mktemp readlink pgrep gpg
[[ "$(uname -m)" == 'x86_64' ]] || die 'This installer requires an x86_64 architecture.'
[[ -f "$REPO_DIR/files/google-chrome-stable" ]] || die 'Missing files/google-chrome-stable.'
[[ -f "$REPO_DIR/files/update-dialog.py" ]] || die 'Missing files/update-dialog.py.'
[[ -f "$REPO_DIR/files/update-dialog.html" ]] || die 'Missing files/update-dialog.html.'
[[ -f "$REPO_DIR/files/google-chrome.desktop.in" ]] || die 'Missing files/google-chrome.desktop.in.'

mkdir -p -- "$CACHE_ROOT" "$(dirname -- "$APP_DIR")"
WORK_DIR="$(mktemp -d "$CACHE_ROOT/install.XXXXXXXX")"
trap cleanup EXIT

deb_file=""
expected_sha256=""
if [[ -n "$deb_override" ]]; then
    deb_file="$(readlink -f -- "$deb_override")"
    [[ -f "$deb_file" ]] || die "Package does not exist: $deb_override"
    raw_version="$(version_from_deb "$deb_file")"
    [[ -n "$raw_version" ]] || die 'Could not read the .deb version.'
else
    package_data="$(package_info "$WORK_DIR/Packages")"
    [[ -n "$package_data" ]] || die 'Could not retrieve stable Chrome package information.'
    IFS=$'\t' read -r raw_version filename expected_sha256 <<< "$package_data"
    deb_url="${DEB_BASE_URL}/${filename#/}"
    deb_file="$WORK_DIR/google-chrome-stable_${raw_version}_amd64.deb"
    printf 'Downloading Google Chrome from:\n%s\n' "$deb_url"
    curl --fail --location --retry 3 --connect-timeout 15 --progress-bar \
        --output "$deb_file" "$deb_url"
fi

if [[ -n "$expected_sha256" ]]; then
    checksum_line="$(sha256sum "$deb_file")"
    actual_sha256="${checksum_line%% *}"
    [[ "$actual_sha256" == "$expected_sha256" ]] || \
        die 'The SHA256 checksum of the downloaded package does not match.'
fi

stage_dir="$WORK_DIR/payload"
mkdir -p -- "$stage_dir"
ar p "$deb_file" data.tar.xz | bsdtar -xpf - -C "$stage_dir" \
    --strip-components=4 ./opt/google/chrome
[[ -e "$stage_dir/chrome-sandbox" ]] || die 'The package does not contain chrome-sandbox.'
chmod 0755 "$stage_dir/chrome-sandbox"
link_system_libraries "$stage_dir"
cp -- "$REPO_DIR/files/google-chrome-stable" "$stage_dir/google-chrome-stable"
cp -- "$REPO_DIR/files/update-dialog.py" "$stage_dir/update-dialog.py"
cp -- "$REPO_DIR/files/update-dialog.html" "$stage_dir/update-dialog.html"
chmod 0755 "$stage_dir/google-chrome-stable" "$stage_dir/update-dialog.py"

staged_version="$("$stage_dir/chrome" --version 2>/dev/null | sed -n 's/^Google Chrome //p' | tr -d '[:space:]')"
expected_version="${raw_version%-*}"
[[ "$staged_version" == "$expected_version" ]] || \
    die 'The extracted version does not match the package version.'

backup_dir=""
if [[ -e "$APP_DIR" ]]; then
    backup_dir="${APP_DIR}.backup.install.$$"
    [[ ! -e "$backup_dir" ]] || die "Already exists: $backup_dir"
    mv -- "$APP_DIR" "$backup_dir"
fi
if ! mv -- "$stage_dir" "$APP_DIR"; then
    [[ -z "$backup_dir" ]] || mv -- "$backup_dir" "$APP_DIR" || true
    die 'Could not activate the installation.'
fi

mkdir -p -- "$BIN_DIR" "$DESKTOP_DIR"
ln -sfn -- "$APP_DIR/google-chrome-stable" "$BIN_DIR/google-chrome-stable"
ln -sfn -- "$APP_DIR/google-chrome-stable" "$BIN_DIR/google-chrome"

replacement="${APP_DIR//\\/\\\\}"
replacement="${replacement//&/\\&}"
replacement="${replacement//|/\\|}"
sed "s|@APP_DIR@|$replacement|g" \
    "$REPO_DIR/files/google-chrome.desktop.in" > "$DESKTOP_DIR/google-chrome.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DESKTOP_DIR" || true
fi
if command -v kbuildsycoca6 >/dev/null 2>&1; then
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
fi

if [[ -n "$backup_dir" ]]; then
    if chrome_running; then
        printf 'Keeping the backup while Chrome is open: %s\n' "$backup_dir"
    else
        rm -rf -- "$backup_dir"
    fi
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        printf 'Note: %s is not currently in your PATH.\n' "$BIN_DIR"
        printf 'Run: export PATH=%q:$PATH\n' "$BIN_DIR"
        ;;
esac

printf 'Google Chrome %s installed at %s.\n' "$staged_version" "$APP_DIR"
"$APP_DIR/google-chrome-stable" update --check
