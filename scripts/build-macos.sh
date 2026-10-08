#!/usr/bin/env bash
# Builds ngx_http_kafka_log_module.so (this repository's checked-out branch) and the njs module
# for Homebrew nginx on macOS, against the nginx version that is currently installed.
#
# Usage:
#   scripts/build-macos.sh              build only, print where the .so files are
#   scripts/build-macos.sh --install    build, then install the .so files into Homebrew's nginx modules dir
#
# Optional environment:
#   BUILD_DIR     where nginx and njs sources are kept   (default: $HOME/nginx-build)
#   NGX_VERSION   nginx version to build against          (default: the installed one, from `nginx -v`)
#   MODULES_DIR   where --install copies the .so files    (default: $(brew --prefix)/etc/nginx/modules)
#
# The resulting .so files only work on this OS and CPU architecture, with the same nginx version and flags.
# Paths must not contain spaces.
set -euo pipefail

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "this script is for macOS; use scripts/build-linux.sh on Linux"
for tool in brew nginx curl tar make cc git sed; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BREW_PREFIX="$(brew --prefix)"
BUILD_DIR="${BUILD_DIR:-$HOME/nginx-build}"
NGX_VERSION="${NGX_VERSION:-$(nginx -v 2>&1 | sed 's/.*nginx\///')}"
MODULES_DIR="${MODULES_DIR:-$BREW_PREFIX/etc/nginx/modules}"
NGX_SRC="$BUILD_DIR/nginx-$NGX_VERSION"
NJS_DIR="$BUILD_DIR/njs"

echo "== Build settings"
echo "arch:            $(uname -m)"
echo "nginx version:   $NGX_VERSION"
echo "module source:   $REPO_DIR (branch: $(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo unknown))"
echo "build directory: $BUILD_DIR"

brew list --versions librdkafka >/dev/null 2>&1 || fail "librdkafka is not installed. Run: brew install librdkafka"

echo "== Checking librdkafka features"
EXTRA_CFLAGS="-I$BREW_PREFIX/include" \
EXTRA_LDFLAGS="-L$BREW_PREFIX/lib -Wl,-rpath,$BREW_PREFIX/lib" \
    "$REPO_DIR/scripts/check-librdkafka.sh"

echo "== Fetching sources"
mkdir -p "$BUILD_DIR"
if [ ! -d "$NGX_SRC" ]; then
    (cd "$BUILD_DIR" && curl -fSLO "https://nginx.org/download/nginx-$NGX_VERSION.tar.gz" && tar xzf "nginx-$NGX_VERSION.tar.gz")
fi
if [ ! -d "$NJS_DIR" ]; then
    git clone --depth 1 https://github.com/nginx/njs.git "$NJS_DIR"
fi

echo "== Configuring"
# Reuse the flags Homebrew built nginx with, so the modules are binary compatible.
ARGS="$(nginx -V 2>&1 | sed -n 's/^configure arguments: //p')"
[ -n "$ARGS" ] || fail "could not read configure arguments from 'nginx -V'"

# Homebrew's librdkafka lives outside the compiler's default search path, and nginx's -Werror
# would stop the build on a warning that is inside librdkafka's own header (rdkafka.h).
q="'"
case "$ARGS" in
    *"--with-cc-opt=$q"*) ARGS="${ARGS/--with-cc-opt=$q/--with-cc-opt=$q-I$BREW_PREFIX/include -Wno-error }" ;;
    *) ARGS="$ARGS --with-cc-opt=${q}-I$BREW_PREFIX/include -Wno-error$q" ;;
esac
case "$ARGS" in
    *"--with-ld-opt=$q"*) ARGS="${ARGS/--with-ld-opt=$q/--with-ld-opt=$q-L$BREW_PREFIX/lib }" ;;
    *) ARGS="$ARGS --with-ld-opt=${q}-L$BREW_PREFIX/lib$q" ;;
esac

cd "$NGX_SRC"
make clean >/dev/null 2>&1 || true
eval "./configure $ARGS --with-compat \
    --add-dynamic-module=$(printf '%q' "$REPO_DIR") \
    --add-dynamic-module=$(printf '%q' "$NJS_DIR/nginx")"

echo "== Compiling"
make modules

KAFKA_SO="$NGX_SRC/objs/ngx_http_kafka_log_module.so"
JS_SO="$NGX_SRC/objs/ngx_http_js_module.so"
[ -f "$KAFKA_SO" ] || fail "build did not produce $KAFKA_SO"
[ -f "$JS_SO" ] || fail "build did not produce $JS_SO"

echo "== Built files"
file "$KAFKA_SO" "$JS_SO"
echo "linked libraries of the kafka module:"
otool -L "$KAFKA_SO" | grep -i rdkafka || fail "the kafka module is not linked against librdkafka"

if [ "$INSTALL" -eq 1 ]; then
    echo "== Installing into $MODULES_DIR"
    mkdir -p "$MODULES_DIR"
    # Delete before copying. Copying over an existing .so in place can make macOS kill nginx
    # (SIGKILL, "Code Signature Invalid") when it loads the module.
    rm -f "$MODULES_DIR/ngx_http_kafka_log_module.so" "$MODULES_DIR/ngx_http_js_module.so"
    cp "$KAFKA_SO" "$MODULES_DIR/"
    cp "$JS_SO" "$MODULES_DIR/"
    ls -l "$MODULES_DIR"
else
    echo "Not installed (run again with --install)."
fi

cat <<EOF

== Next steps
1. Download Akto's njs script (once):
   mkdir -p $BREW_PREFIX/etc/nginx/njs
   curl -o $BREW_PREFIX/etc/nginx/njs/api_log.js https://raw.githubusercontent.com/akto-api-security/nginx-middleware/master/api_log.js
2. Edit $BREW_PREFIX/etc/nginx/nginx.conf as described in BUILD_COMMANDS.md.
3. Check and restart:
   nginx -t
   brew services restart nginx
   ps -eo pid,lstart,command | grep "[n]ginx: master"    # start time must be recent
EOF
