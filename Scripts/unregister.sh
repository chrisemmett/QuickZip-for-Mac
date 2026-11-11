#!/bin/bash
# Removes every copy of QuickZip that macOS has registered (Launch Services,
# the Quick Look extension, Services), so the next install is the only one.
#
#   Scripts/unregister.sh                     unregister every copy
#   Scripts/unregister.sh --keep /Applications/QuickZip.app
#                                             ...except this one, re-registered
#   Scripts/unregister.sh --dry-run           only list what would happen
#
# Options:
#   --keep PATH   leave this copy registered (and register it again cleanly)
#   --purge       also delete Xcode's DerivedData builds and QuickZip's data:
#                 sandbox containers (settings, remembered folders) and
#                 passwords saved in the Keychain
#   --rebuild     also rebuild the whole Launch Services database. Clears
#                 records of copies already deleted from disk, but affects
#                 every app ("Open with" choices are kept; some apps may ask
#                 again whether to open after downloading)
#   --dry-run     print the plan and stop
#   -y, --yes     do not ask before starting
#
# Copies are found from Launch Services, pluginkit, Spotlight and the usual
# build folders. Copies are unregistered, not deleted, except DerivedData
# builds with --purge; Xcode archives are left on disk.
#
# The bundle identifiers are read from BUNDLE_ID_PREFIX in the environment,
# Config/Local.xcconfig or Config/Base.xcconfig, in that order.

# Run with bash even when started as "sh unregister.sh" (macOS's sh is bash in
# POSIX mode, or another shell, and cannot read this script).
if [ -z "${BASH_VERSION:-}" ]; then exec /bin/bash "$0" "$@"; fi
case ":${SHELLOPTS:-}:" in *:posix:*) exec /bin/bash "$0" "$@" ;; esac

set -euo pipefail

# The bundle identifiers come from BUNDLE_ID_PREFIX: the environment if set,
# else Config/Local.xcconfig, else the placeholder in Config/Base.xcconfig.
xcconfig_prefix() {
    [ -f "$1" ] || return 0
    sed -n 's/^[[:space:]]*BUNDLE_ID_PREFIX[[:space:]]*=[[:space:]]*\([^[:space:]/]*\).*/\1/p' "$1" | tail -n 1
}
CONFIG_DIR="$(cd "$(dirname "$0")/../Config" 2>/dev/null && pwd || true)"
PREFIX="${BUNDLE_ID_PREFIX:-}"
[ -n "$PREFIX" ] || PREFIX=$(xcconfig_prefix "$CONFIG_DIR/Local.xcconfig")
[ -n "$PREFIX" ] || PREFIX=$(xcconfig_prefix "$CONFIG_DIR/Base.xcconfig")
[ -n "$PREFIX" ] || { echo "Set BUNDLE_ID_PREFIX (see Config/Base.xcconfig)." >&2; exit 1; }

APP_ID=$PREFIX.QuickZip
QL_ID=$PREFIX.QuickZip.QuickLook
KEYCHAIN_SERVICE=$APP_ID.archive-password
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

keep=""
purge=0
rebuild=0
dry_run=0
assume_yes=0

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --keep)    [ $# -ge 2 ] || usage 1; keep="$2"; shift ;;
        --purge)   purge=1 ;;
        --rebuild) rebuild=1 ;;
        --dry-run) dry_run=1 ;;
        -y|--yes)  assume_yes=1 ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

[ "$(uname)" = Darwin ] || { echo "This script runs on macOS." >&2; exit 1; }
[ -x "$LSREGISTER" ] || { echo "lsregister not found at $LSREGISTER" >&2; exit 1; }

# Resolves symlinks and relative parts of a bundle path that exists.
canonical() {
    if [ -d "$1" ]; then (cd "$1" && pwd -P); else printf '%s\n' "$1"; fi
}

if [ -n "$keep" ]; then
    [ -d "$keep/Contents" ] || { echo "--keep: $keep is not an app bundle." >&2; exit 1; }
    keep=$(canonical "$keep")
fi

# --- Find every copy ---------------------------------------------------------

found=$(mktemp)
sorted=$(mktemp)
trap 'rm -f "$found" "$sorted"' EXIT

# Launch Services: records are separated by lines of dashes; each has a
# "path:" and an "identifier:" (older systems: "bundle id:") line.
"$LSREGISTER" -dump 2>/dev/null | awk -v app="$APP_ID" -v ql="$QL_ID" '
    /^--------------------/ { if (path != "" && (id == app || id == ql)) print path; path = ""; id = ""; next }
    /^[[:space:]]*path:/ {
        sub(/^[[:space:]]*path:[[:space:]]*/, ""); sub(/ \(0x[0-9a-fA-F]+\)$/, ""); path = $0; next
    }
    /^[[:space:]]*(identifier|bundle id):/ {
        sub(/^[[:space:]]*(identifier|bundle id):[[:space:]]*/, ""); sub(/ \(0x[0-9a-fA-F]+\)$/, "")
        if ($0 ~ /\./) id = $0   # newer dumps also have a numeric "bundle id:"
        next
    }
    END { if (path != "" && (id == app || id == ql)) print path }
' >>"$found" || true

# pluginkit: the extension path is the last tab-separated field.
pluginkit -m -A -D -v -i "$QL_ID" 2>/dev/null | awk -F '\t' 'NF > 1 { print $NF }' >>"$found" || true

# Spotlight finds copies in the Trash, in Xcode archives and anywhere else.
mdfind "kMDItemCFBundleIdentifier == '$APP_ID'" 2>/dev/null >>"$found" || true

# The usual build folders, in case Spotlight skips them.
repo=$(cd "$(dirname "$0")/.." && pwd -P)
for dir in "$HOME/Library/Developer/Xcode/DerivedData" "$repo/Build" /Applications "$HOME/Applications"; do
    [ -d "$dir" ] && find "$dir" -maxdepth 6 -name QuickZip.app -type d -prune 2>/dev/null >>"$found"
done

# Turn each path into its app bundle, so an extension inside an app counts
# as that app. A standalone .appex record (its app gone) stays as it is.
sort -u "$found" >"$sorted"
apps=()
stale_extensions=()
while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
        *.app/Contents/PlugIns/*.appex) app=${path%%/Contents/PlugIns/*} ;;
        *.app) app=$path ;;
        *.appex) stale_extensions+=("$path"); continue ;;
        *) continue ;;
    esac
    apps+=("$app")
done <"$sorted"

# Deduplicate after resolving symlinks (/Applications vs a link to it, etc.).
unique_apps=()
if [ ${#apps[@]} -gt 0 ]; then
    for app in "${apps[@]}"; do canonical "$app"; done | sort -u >"$sorted"
    while IFS= read -r app; do unique_apps+=("$app"); done <"$sorted"
fi

# --- Plan ----------------------------------------------------------------------

remove=()
keep_registered=0
for app in ${unique_apps[@]+"${unique_apps[@]}"}; do
    if [ "$app" = "$keep" ]; then keep_registered=1; else remove+=("$app"); fi
done

echo "Registered copies of QuickZip:"
if [ ${#unique_apps[@]} -eq 0 ] && [ ${#stale_extensions[@]} -eq 0 ]; then
    echo "  (none found)"
fi
for app in ${unique_apps[@]+"${unique_apps[@]}"}; do
    note=""
    [ -d "$app" ] || note=" (no longer on disk)"
    if [ "$app" = "$keep" ]; then echo "  keep        $app"; else echo "  unregister  $app$note"; fi
done
for appex in ${stale_extensions[@]+"${stale_extensions[@]}"}; do
    echo "  unregister  $appex (extension on its own)"
done
[ -n "$keep" ] && [ $keep_registered -eq 0 ] && echo "  register    $keep"
[ $purge -eq 1 ] && echo "Also: delete DerivedData copies, sandbox containers and saved Keychain passwords."
[ $rebuild -eq 1 ] && echo "Also: rebuild the Launch Services database."
echo

if [ $dry_run -eq 1 ]; then
    echo "Dry run: nothing changed."
    exit 0
fi
if [ $assume_yes -eq 0 ]; then
    printf "Quit QuickZip and go ahead? [y/N] "
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Nothing changed."; exit 0 ;; esac
fi

run() { echo "  \$ $*"; "$@" || echo "    (failed, continuing)"; }

# --- Act -----------------------------------------------------------------------

echo "==> Quitting QuickZip and its Quick Look extension"
osascript -e "tell application id \"$APP_ID\" to quit" >/dev/null 2>&1 || true
pkill -x QuickZip 2>/dev/null || true
pkill -x QuickZipQuickLook 2>/dev/null || true

echo "==> Unregistering"
for app in ${remove[@]+"${remove[@]}"}; do
    appex="$app/Contents/PlugIns/QuickZipQuickLook.appex"
    run pluginkit -r "$appex"
    run "$LSREGISTER" -u "$appex"
    run "$LSREGISTER" -u "$app"
done
for appex in ${stale_extensions[@]+"${stale_extensions[@]}"}; do
    run pluginkit -r "$appex"
    run "$LSREGISTER" -u "$appex"
done

# The quickzip command is a symbolic link into one copy of the app.
for link in /usr/local/bin/quickzip /opt/homebrew/bin/quickzip "$HOME/.local/bin/quickzip"; do
    [ -L "$link" ] || continue
    target=$(readlink "$link")
    if [ -n "$keep" ] && [ "$target" = "$keep/Contents/Helpers/quickzip" ]; then continue; fi
    echo "==> Removing the quickzip command at $link (it pointed to $target)"
    rm -f "$link" 2>/dev/null || sudo rm -f "$link" || echo "    (could not remove $link)"
done

if [ $purge -eq 1 ]; then
    echo "==> Deleting DerivedData copies"
    for app in ${remove[@]+"${remove[@]}"}; do
        case "$app" in
            "$HOME/Library/Developer/Xcode/DerivedData/"*) [ -d "$app" ] && run rm -rf "$app" ;;
        esac
    done
    echo "==> Deleting QuickZip's data"
    for container in "$HOME/Library/Containers/$APP_ID" "$HOME/Library/Containers/$QL_ID"; do
        if [ -d "$container" ]; then
            rm -rf "$container" 2>/dev/null \
                || echo "  Could not delete $container; delete it in Finder (macOS protects containers from Terminal)."
        fi
    done
    defaults delete "$APP_ID" >/dev/null 2>&1 || true
    # One item per archive; delete until none are left.
    for _ in $(seq 1 1000); do
        security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || break
    done
fi

if [ $rebuild -eq 1 ]; then
    echo "==> Rebuilding the Launch Services database (this can take a minute)"
    run "$LSREGISTER" -kill -r -domain local -domain system -domain user
fi

if [ -n "$keep" ]; then
    echo "==> Registering $keep"
    run "$LSREGISTER" -f -R "$keep"
    run pluginkit -a "$keep/Contents/PlugIns/QuickZipQuickLook.appex"
fi

echo "==> Refreshing Quick Look, Services and Finder"
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
killall Finder 2>/dev/null || true

echo
echo "Quick Look extensions now registered:"
pluginkit -m -A -D -v -i "$QL_ID" 2>/dev/null | sed 's/^/  /' || true
[ -n "$(pluginkit -m -A -D -i "$QL_ID" 2>/dev/null)" ] || echo "  (none)"
echo
echo "Quit and reopen System Settings to see the list change."
if [ -z "$keep" ]; then
    echo "To install fresh: copy QuickZip.app to /Applications, open it once, then run qlmanage -r."
fi
echo "Copies left on disk (the repository's Build folder, Xcode archives, the Trash)"
echo "can be registered again if they are opened or indexed. Empty the Trash, and"
echo "run this script again if an extra copy comes back."
