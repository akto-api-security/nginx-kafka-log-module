#!/usr/bin/env bash
# Builds ngx_http_kafka_log_module.so (this repository's checked-out branch) for nginx installed from
# the nginx.org packages on Debian/Ubuntu, against the nginx version that is currently installed.
# The njs module is NOT built here; install it from the same repository: apt install nginx-module-njs
#
# Usage:
#   scripts/build-linux.sh                       build only, print where the .so file is
#   scripts/build-linux.sh --install-deps        also apt-install the build dependencies first
#   scripts/build-linux.sh --install             build, then install the .so into nginx's modules dir
#   (options can be combined)
#
# Optional environment:
#   BUILD_DIR      where the nginx source is kept             (default: $HOME/nginx-build)
#   NGX_VERSION    nginx version to build against             (default: the installed one, from `nginx -v`)
#   MODULES_DIR    where --install copies the .so             (default: the --modules-path of the installed nginx)
#   EXTRA_CC_OPT   extra compiler flags, e.g. -Wno-error if a newer librdkafka header trips -Werror
#
# The resulting .so only works on this OS, CPU architecture and C library, with the same nginx version
# and flags. Build on the same distribution and architecture that will run it. Paths must not contain spaces.
set -euo pipefail

INSTALL=0
INSTALL_DEPS=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --install-deps) INSTALL_DEPS=1 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || fail "this script is for Linux; use scripts/build-macos.sh on macOS"
command -v apt-get >/dev/null 2>&1 || fail "only Debian/Ubuntu (apt) is supported by this script"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || fail "run as root or install sudo"
    SUDO="sudo"
fi

if [ "$INSTALL_DEPS" -eq 1 ]; then
    echo "== Installing build dependencies"
    $SUDO apt-get update
    $SUDO apt-get install -y build-essential curl ca-certificates tar \
        libpcre2-dev libpcre3-dev zlib1g-dev libssl-dev librdkafka-dev
fi

for tool in nginx curl tar make cc sed; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool (try --install-deps; nginx must already be installed)"
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$HOME/nginx-build}"
NGX_VERSION="${NGX_VERSION:-$(nginx -v 2>&1 | sed 's/.*nginx\///')}"
NGX_SRC="$BUILD_DIR/nginx-$NGX_VERSION"
DEFAULT_MODULES_DIR="$(nginx -V 2>&1 | grep -o -- '--modules-path=[^ ]*' | cut -d= -f2 || true)"
MODULES_DIR="${MODULES_DIR:-${DEFAULT_MODULES_DIR:-/usr/lib/nginx/modules}}"

echo "== Build settings"
echo "os:              $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "arch:            $(uname -m)"
echo "nginx version:   $NGX_VERSION"
echo "module source:   $REPO_DIR (branch: $(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo unknown))"
echo "build directory: $BUILD_DIR"
echo "modules dir:     $MODULES_DIR"

echo "== Checking librdkafka features"
"$REPO_DIR/scripts/check-librdkafka.sh"

echo "== Fetching nginx source"
mkdir -p "$BUILD_DIR"
if [ ! -d "$NGX_SRC" ]; then
    (cd "$BUILD_DIR" && curl -fSLO "https://nginx.org/download/nginx-$NGX_VERSION.tar.gz" && tar xzf "nginx-$NGX_VERSION.tar.gz")
fi

echo "== Configuring"
# Reuse the flags the installed nginx was built with, so the module is binary compatible.
ARGS="$(nginx -V 2>&1 | sed -n 's/^configure arguments: //p')"
[ -n "$ARGS" ] || fail "could not read configure arguments from 'nginx -V'"

if [ -n "${EXTRA_CC_OPT:-}" ]; then
    q="'"
    case "$ARGS" in
        *"--with-cc-opt=$q"*) ARGS="${ARGS/--with-cc-opt=$q/--with-cc-opt=$q$EXTRA_CC_OPT }" ;;
        *) ARGS="$ARGS --with-cc-opt=$q$EXTRA_CC_OPT$q" ;;
    esac
fi

cd "$NGX_SRC"
make clean >/dev/null 2>&1 || true
eval "./configure $ARGS --with-compat --add-dynamic-module=$(printf '%q' "$REPO_DIR")"

echo "== Compiling"
make modules

KAFKA_SO="$NGX_SRC/objs/ngx_http_kafka_log_module.so"
[ -f "$KAFKA_SO" ] || fail "build did not produce $KAFKA_SO"

echo "== Built file"
file "$KAFKA_SO" 2>/dev/null || ls -l "$KAFKA_SO"
echo "linked libraries of the kafka module:"
ldd "$KAFKA_SO" | grep -i rdkafka || fail "the kafka module is not linked against librdkafka"

if [ "$INSTALL" -eq 1 ]; then
    echo "== Installing into $MODULES_DIR"
    $SUDO mkdir -p "$MODULES_DIR"
    $SUDO rm -f "$MODULES_DIR/ngx_http_kafka_log_module.so"
    $SUDO install -m 0644 "$KAFKA_SO" "$MODULES_DIR/ngx_http_kafka_log_module.so"
    ls -l "$MODULES_DIR/ngx_http_kafka_log_module.so"
else
    echo "Not installed (run again with --install)."
fi

if [ ! -f "$MODULES_DIR/ngx_http_js_module.so" ]; then
    echo "WARNING: $MODULES_DIR/ngx_http_js_module.so not found. Install the njs module: apt install nginx-module-njs" >&2
fi

cat <<'EOF'

== Next steps
1. Download Akto's njs script (once):
   sudo mkdir -p /etc/nginx/njs
   sudo curl -o /etc/nginx/njs/api_log.js https://raw.githubusercontent.com/akto-api-security/nginx-middleware/master/api_log.js
2. Edit /etc/nginx/nginx.conf and /etc/nginx/conf.d/default.conf as described in BUILD_COMMANDS.md.
3. Check and restart:
   sudo nginx -t
   sudo systemctl restart nginx
   ps -eo pid,lstart,command | grep "[n]ginx: master"    # start time must be recent
EOF
