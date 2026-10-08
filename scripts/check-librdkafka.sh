#!/usr/bin/env bash
# Prints the version and built-in features of the librdkafka this machine would link against,
# and fails if the features needed for SASL/PLAIN authentication are missing.
#
# Optional environment:
#   CC               C compiler (default: cc)
#   EXTRA_CFLAGS     extra compiler flags, e.g. -I/opt/homebrew/include
#   EXTRA_LDFLAGS    extra linker flags, e.g. -L/opt/homebrew/lib -Wl,-rpath,/opt/homebrew/lib
set -euo pipefail

CC_BIN="${CC:-cc}"
EXTRA_CFLAGS="${EXTRA_CFLAGS:-}"
EXTRA_LDFLAGS="${EXTRA_LDFLAGS:-}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/feat.c" <<'EOF'
#include <stdio.h>
#include <librdkafka/rdkafka.h>

int main(void) {
    rd_kafka_conf_t *conf = rd_kafka_conf_new();
    char features[1024];
    size_t size = sizeof(features);

    if (rd_kafka_conf_get(conf, "builtin.features", features, &size) != RD_KAFKA_CONF_OK) {
        fprintf(stderr, "could not read builtin.features\n");
        return 2;
    }
    printf("version=%s\n", rd_kafka_version_str());
    printf("features=%s\n", features);
    rd_kafka_conf_destroy(conf);
    return 0;
}
EOF

# shellcheck disable=SC2086
"$CC_BIN" $EXTRA_CFLAGS "$tmp/feat.c" $EXTRA_LDFLAGS -lrdkafka -o "$tmp/feat"

output="$("$tmp/feat")"
echo "$output"

features=",$(echo "$output" | sed -n 's/^features=//p'),"

missing=""
for required in sasl sasl_plain ssl; do
    case "$features" in
        *",$required,"*) ;;
        *) missing="$missing $required" ;;
    esac
done

if [ -n "$missing" ]; then
    echo "ERROR: librdkafka is missing required feature(s):$missing" >&2
    echo "       SASL/PLAIN over SASL_SSL needs 'sasl', 'sasl_plain' and 'ssl'." >&2
    exit 1
fi

for optional in sasl_scram sasl_gssapi sasl_oauthbearer; do
    case "$features" in
        *",$optional,"*) echo "$optional: available" ;;
        *) echo "$optional: NOT available" ;;
    esac
done
