#!/usr/bin/env bash
# Builds ngx_http_kafka_log_module.so from this repository's checked-out branch, for nginx installed from
# the nginx.org packages on Debian/Ubuntu, against the installed nginx version.
# It does not install nginx or njs and does not touch nginx.conf.
#
# Usage: scripts/build-linux.sh [--install-deps] [--install]
#   --install-deps   apt-install the build dependencies first
#   --install        copy the built module into nginx's modules directory
#
# Optional environment: BUILD_DIR (default ~/nginx-build), NGX_VERSION (default: installed version),
#   MODULES_DIR (default: nginx's --modules-path), EXTRA_CC_OPT (extra compiler flags, e.g. -Wno-error)

set -euo pipefail

INSTALL=0
INSTALL_DEPS=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --install-deps) INSTALL_DEPS=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || fail "this script is for Linux; use scripts/build-macos.sh on macOS"
command -v apt-get >/dev/null 2>&1 || fail "only Debian/Ubuntu (apt) is supported"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || fail "run as root or install sudo"
    SUDO="sudo"
fi

if [ "$INSTALL_DEPS" -eq 1 ]; then
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq build-essential curl ca-certificates tar \
        libpcre2-dev libpcre3-dev zlib1g-dev libssl-dev librdkafka-dev
fi

for tool in nginx curl tar make cc sed; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool (nginx must already be installed; try --install-deps for the rest)"
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$HOME/nginx-build}"
NGX_VERSION="${NGX_VERSION:-$(nginx -v 2>&1 | sed 's/.*nginx\///')}"
NGX_SRC="$BUILD_DIR/nginx-$NGX_VERSION"
DETECTED_MODULES_DIR="$(nginx -V 2>&1 | grep -o -- '--modules-path=[^ ]*' | cut -d= -f2 || true)"
MODULES_DIR="${MODULES_DIR:-${DETECTED_MODULES_DIR:-/usr/lib/nginx/modules}}"
KAFKA_SO="$NGX_SRC/objs/ngx_http_kafka_log_module.so"

echo "Building for nginx $NGX_VERSION on $(uname -m) (module branch: $(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo unknown))"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The module needs a librdkafka with SASL (PLAIN) and SSL support.
cat > "$tmp/features.c" <<'EOF'
#include <stdio.h>
#include <librdkafka/rdkafka.h>
int main(void) {
    char features[1024];
    size_t size = sizeof(features);
    rd_kafka_conf_t *conf = rd_kafka_conf_new();
    if (rd_kafka_conf_get(conf, "builtin.features", features, &size) != RD_KAFKA_CONF_OK) return 2;
    printf("%s|%s\n", rd_kafka_version_str(), features);
    return 0;
}
EOF
cc -w "$tmp/features.c" -lrdkafka -o "$tmp/features" || fail "librdkafka development files not found (apt-get install librdkafka-dev)"
out="$("$tmp/features")"
for feature in sasl sasl_plain ssl; do
    case ",${out#*|}," in
        *",$feature,"*) ;;
        *) fail "librdkafka ${out%%|*} does not support '$feature' (features: ${out#*|})" ;;
    esac
done
echo "librdkafka ${out%%|*}: ${out#*|}"

mkdir -p "$BUILD_DIR"
if [ ! -d "$NGX_SRC" ]; then
    (cd "$BUILD_DIR" && curl -fsSLO "https://nginx.org/download/nginx-$NGX_VERSION.tar.gz" && tar xzf "nginx-$NGX_VERSION.tar.gz")
fi

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
eval "./configure $ARGS --with-compat --add-dynamic-module=$(printf '%q' "$REPO_DIR")" > "$BUILD_DIR/configure.log" 2>&1 \
    || { tail -n 20 "$BUILD_DIR/configure.log" >&2; fail "configure failed (full log: $BUILD_DIR/configure.log)"; }
make modules > "$BUILD_DIR/make.log" 2>&1 \
    || { tail -n 20 "$BUILD_DIR/make.log" >&2; fail "build failed (full log: $BUILD_DIR/make.log)"; }

[ -f "$KAFKA_SO" ] || fail "build did not produce $KAFKA_SO"
ldd "$KAFKA_SO" | grep -q rdkafka || fail "the built module is not linked against librdkafka"
echo "Built: $KAFKA_SO"

if [ "$INSTALL" -eq 1 ]; then
    $SUDO mkdir -p "$MODULES_DIR"
    $SUDO rm -f "$MODULES_DIR/ngx_http_kafka_log_module.so"
    $SUDO install -m 0644 "$KAFKA_SO" "$MODULES_DIR/ngx_http_kafka_log_module.so"
    echo "Installed: $MODULES_DIR/ngx_http_kafka_log_module.so"
else
    echo "Not installed (run again with --install)"
fi

[ -f "$MODULES_DIR/ngx_http_js_module.so" ] || echo "WARNING: njs module not found in $MODULES_DIR (apt install nginx-module-njs)" >&2
