#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="${CHROME_APP_DIR:-$HOME/Apps/google-chrome}"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/google-chrome-local-installer"
PACKAGES_URL="https://dl.google.com/linux/chrome/deb/dists/stable/main/binary-amd64/Packages"
DEB_BASE_URL="https://dl.google.com/linux/chrome/deb"
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
            die "Falta la herramienta requerida: $command_name"
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

package_info() {
    local metadata_file="$1"
    curl --fail --location --retry 3 --connect-timeout 15 \
        --silent --show-error --output "$metadata_file" "$PACKAGES_URL"
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
        [[ -e "$target" ]] || die "No se encuentra la biblioteca requerida: $target"
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
        'Uso: ./install.sh [--deb archivo.deb]' \
        '       CHROME_APP_DIR=~/Apps/google-chrome ./install.sh'
}

deb_override=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --deb)
            [[ "$#" -ge 2 ]] || die '--deb necesita un archivo.'
            deb_override="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Argumento desconocido: $1"
            ;;
    esac
done

require_commands curl awk ar bsdtar sha256sum sed tr mktemp readlink pgrep
[[ "$(uname -m)" == 'x86_64' ]] || die 'Este instalador requiere una arquitectura x86_64.'
[[ -f "$REPO_DIR/files/google-chrome-stable" ]] || die 'Falta files/google-chrome-stable.'
[[ -f "$REPO_DIR/files/update-dialog.py" ]] || die 'Falta files/update-dialog.py.'
[[ -f "$REPO_DIR/files/update-dialog.html" ]] || die 'Falta files/update-dialog.html.'
[[ -f "$REPO_DIR/files/google-chrome.desktop.in" ]] || die 'Falta files/google-chrome.desktop.in.'

mkdir -p -- "$CACHE_ROOT" "$(dirname -- "$APP_DIR")"
WORK_DIR="$(mktemp -d "$CACHE_ROOT/install.XXXXXXXX")"
trap cleanup EXIT

deb_file=""
expected_sha256=""
if [[ -n "$deb_override" ]]; then
    deb_file="$(readlink -f -- "$deb_override")"
    [[ -f "$deb_file" ]] || die "No existe el paquete: $deb_override"
    raw_version="$(version_from_deb "$deb_file")"
    [[ -n "$raw_version" ]] || die 'No se pudo leer la versión del .deb.'
else
    package_data="$(package_info "$WORK_DIR/Packages")"
    [[ -n "$package_data" ]] || die 'No se pudo obtener la información de Chrome estable.'
    IFS=$'\t' read -r raw_version filename expected_sha256 <<< "$package_data"
    deb_url="${DEB_BASE_URL}/${filename#/}"
    deb_file="$WORK_DIR/google-chrome-stable_${raw_version}_amd64.deb"
    printf 'Descargando Google Chrome desde:\n%s\n' "$deb_url"
    curl --fail --location --retry 3 --connect-timeout 15 --progress-bar \
        --output "$deb_file" "$deb_url"
fi

if [[ -n "$expected_sha256" ]]; then
    checksum_line="$(sha256sum "$deb_file")"
    actual_sha256="${checksum_line%% *}"
    [[ "$actual_sha256" == "$expected_sha256" ]] || \
        die 'La suma SHA256 del paquete descargado no coincide.'
fi

stage_dir="$WORK_DIR/payload"
mkdir -p -- "$stage_dir"
ar p "$deb_file" data.tar.xz | bsdtar -xpf - -C "$stage_dir" \
    --strip-components=4 ./opt/google/chrome
[[ -e "$stage_dir/chrome-sandbox" ]] || die 'El paquete no contiene chrome-sandbox.'
chmod 0755 "$stage_dir/chrome-sandbox"
link_system_libraries "$stage_dir"
cp -- "$REPO_DIR/files/google-chrome-stable" "$stage_dir/google-chrome-stable"
cp -- "$REPO_DIR/files/update-dialog.py" "$stage_dir/update-dialog.py"
cp -- "$REPO_DIR/files/update-dialog.html" "$stage_dir/update-dialog.html"
chmod 0755 "$stage_dir/google-chrome-stable" "$stage_dir/update-dialog.py"

staged_version="$("$stage_dir/chrome" --version 2>/dev/null | sed -n 's/^Google Chrome //p' | tr -d '[:space:]')"
expected_version="${raw_version%-*}"
[[ "$staged_version" == "$expected_version" ]] || \
    die 'La versión extraída no coincide con la versión del paquete.'

backup_dir=""
if [[ -e "$APP_DIR" ]]; then
    backup_dir="${APP_DIR}.backup.install.$$"
    [[ ! -e "$backup_dir" ]] || die "Ya existe: $backup_dir"
    mv -- "$APP_DIR" "$backup_dir"
fi
if ! mv -- "$stage_dir" "$APP_DIR"; then
    [[ -z "$backup_dir" ]] || mv -- "$backup_dir" "$APP_DIR" || true
    die 'No se pudo activar la instalación.'
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
        printf 'Se conserva el respaldo mientras Chrome esté abierto: %s\n' "$backup_dir"
    else
        rm -rf -- "$backup_dir"
    fi
fi

printf 'Google Chrome %s instalado en %s.\n' "$staged_version" "$APP_DIR"
"$APP_DIR/google-chrome-stable" update --check
