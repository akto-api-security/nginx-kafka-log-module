#!/usr/bin/env bash
# Builds ngx_http_kafka_log_module.so (from this repository's checked-out branch) and the njs module for
# Homebrew nginx on macOS, against the installed nginx version. It does not touch nginx.conf.
#
# Usage: scripts/build-macos.sh [--install]
#   --install   copy the built modules into Homebrew nginx's modules directory
#
# Optional environment: BUILD_DIR (default ~/nginx-build), NGX_VERSION (default: installed version),
#   MODULES_DIR (default: $(brew --prefix)/etc/nginx/modules)

set -euo pipefail

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "this script is for macOS; use scripts/build-linux.sh on Linux"
for tool in brew nginx curl tar make cc git sed; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done
brew list --versions librdkafka >/dev/null 2>&1 || fail "librdkafka is not installed (brew install librdkafka)"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BREW_PREFIX="$(brew --prefix)"
BUILD_DIR="${BUILD_DIR:-$HOME/nginx-build}"
NGX_VERSION="${NGX_VERSION:-$(nginx -v 2>&1 | sed 's/.*nginx\///')}"
MODULES_DIR="${MODULES_DIR:-$BREW_PREFIX/etc/nginx/modules}"
NGX_SRC="$BUILD_DIR/nginx-$NGX_VERSION"
NJS_DIR="$BUILD_DIR/njs"
KAFKA_SO="$NGX_SRC/objs/ngx_http_kafka_log_module.so"
JS_SO="$NGX_SRC/objs/ngx_http_js_module.so"

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
cc -w -I"$BREW_PREFIX/include" "$tmp/features.c" -L"$BREW_PREFIX/lib" -Wl,-rpath,"$BREW_PREFIX/lib" -lrdkafka -o "$tmp/features" \
    || fail "could not compile against librdkafka"
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
if [ ! -d "$NJS_DIR" ]; then
    git clone -q --depth 1 https://github.com/nginx/njs.git "$NJS_DIR"
fi

# Reuse the flags Homebrew built nginx with, so the modules are binary compatible. Add the Homebrew
# include/library paths (so librdkafka is found) and -Wno-error (nginx's -Werror would stop the build on
# a warning inside librdkafka's own header).
ARGS="$(nginx -V 2>&1 | sed -n 's/^configure arguments: //p')"
[ -n "$ARGS" ] || fail "could not read configure arguments from 'nginx -V'"
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
    --add-dynamic-module=$(printf '%q' "$NJS_DIR/nginx")" > "$BUILD_DIR/configure.log" 2>&1 \
    || { tail -n 20 "$BUILD_DIR/configure.log" >&2; fail "configure failed (full log: $BUILD_DIR/configure.log)"; }
make modules > "$BUILD_DIR/make.log" 2>&1 \
    || { tail -n 20 "$BUILD_DIR/make.log" >&2; fail "build failed (full log: $BUILD_DIR/make.log)"; }

[ -f "$KAFKA_SO" ] && [ -f "$JS_SO" ] || fail "build did not produce the module files in $NGX_SRC/objs"
otool -L "$KAFKA_SO" | grep -q rdkafka || fail "the built module is not linked against librdkafka"
echo "Built: $KAFKA_SO"
echo "Built: $JS_SO"

if [ "$INSTALL" -eq 1 ]; then
    mkdir -p "$MODULES_DIR"
    # Delete before copying. Copying over an existing .so in place can make macOS kill nginx
    # (SIGKILL, "Code Signature Invalid") when it loads the module.
    rm -f "$MODULES_DIR/ngx_http_kafka_log_module.so" "$MODULES_DIR/ngx_http_js_module.so"
    cp "$KAFKA_SO" "$JS_SO" "$MODULES_DIR/"
    echo "Installed: $MODULES_DIR"
else
    echo "Not installed (run again with --install)"
fi
