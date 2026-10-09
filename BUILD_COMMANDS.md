# Build scripts

These scripts build `ngx_http_kafka_log_module.so`, the nginx module the Akto connector uses to send traffic to Kafka, from the branch you have checked out. This branch adds SASL authentication support (upstream pull request https://github.com/kaltura/nginx-kafka-log-module/pull/9).

Configuring nginx to use the module is not covered here. Follow the Akto docs: https://docs.akto.io/traffic-connector/api-gateways/nginx

Background reading:
- How nginx dynamic modules are compiled: https://www.f5.com/company/blog/nginx/compiling-dynamic-modules-nginx-plus.html
- nginx packages for Linux: https://nginx.org/en/linux_packages.html
- librdkafka (the Kafka client library): https://docs.confluent.io/kafka-clients/librdkafka/current/overview.html

## Which script

| Platform | Script |
|---|---|
| Debian, Ubuntu (apt-based) | `scripts/build-linux.sh` |
| macOS with Homebrew | `scripts/build-macos.sh` |

Run them from the repository root. Make them executable once with `chmod +x scripts/*.sh`.

A built `.so` only works with the operating system, CPU architecture and nginx version it was built for. Build it on the machine that will run nginx.

## Before you run

- nginx must already be installed. The scripts build against the installed version and do not install nginx.
- Linux: nginx.org packages are expected (`nginx -v` should not say `(Ubuntu)` or `(Debian)`). The Akto connector also needs the njs module (`nginx-module-njs` from the same repository). The script only warns if it is missing.
- macOS: `brew install nginx librdkafka`. The macOS script builds the njs module itself.
- Linux: run as root or with `sudo` available.

## build-linux.sh

```
scripts/build-linux.sh [--install-deps] [--install]
```

| Flag | Meaning |
|---|---|
| `--install-deps` | Install the build dependencies with apt first, including librdkafka from Confluent's apt repository. Without it, the script assumes everything is already installed. |
| `--install` | After building, copy the module into nginx's modules directory (replacing any older copy). Without it, the module is only built, not installed. |
| `-h`, `--help` | Print the usage text and exit. |

Typical first run: `scripts/build-linux.sh --install-deps --install`
Later rebuilds (dependencies already installed): `scripts/build-linux.sh --install`

### What `--install-deps` installs

| Package | Source | Why |
|---|---|---|
| `build-essential` | distribution | C compiler and `make` |
| `curl`, `ca-certificates`, `tar`, `gnupg` | distribution | download and unpack the nginx source, add the Confluent repository |
| `libpcre2-dev`, `libpcre3-dev`, `zlib1g-dev`, `libssl-dev` | distribution | development files nginx's build needs (regex, compression, OpenSSL) |
| `librdkafka-dev` | Confluent (https://packages.confluent.io/clients/deb) | the Kafka client library the module links against |

Confluent publishes the repository for Debian 11, 12, 13 and Ubuntu 20.04, 22.04, 24.04. The script reads the release codename from `/etc/os-release` and stops with a message for any other release. RPM-based distributions and Alpine are not supported.

## build-macos.sh

```
scripts/build-macos.sh [--install]
```

| Flag | Meaning |
|---|---|
| `--install` | After building, copy the kafka and njs modules into Homebrew nginx's modules directory. Without it, the modules are only built. |
| `-h`, `--help` | Print the usage text and exit. |

It does not install dependencies. librdkafka comes from Homebrew (`brew install librdkafka`).

## Environment variables (both scripts)

| Variable | Default | Meaning |
|---|---|---|
| `BUILD_DIR` | `~/nginx-build` | Where the nginx source, logs and build output go. |
| `NGX_VERSION` | the installed nginx version | Build against a different nginx source version. It must match the nginx that will load the module. |
| `MODULES_DIR` | Linux: nginx's `--modules-path`. macOS: `$(brew --prefix)/etc/nginx/modules` | Where `--install` copies the module. |
| `EXTRA_CC_OPT` | none (Linux only) | Extra compiler flags, for example `-Wno-error`. |

Example: `EXTRA_CC_OPT=-Wno-error scripts/build-linux.sh --install`

## What each script does

1. Checks the platform and that the required tools exist.
2. (Linux, with `--install-deps`) Installs the dependencies.
3. Checks that librdkafka supports `sasl`, `sasl_plain` and `ssl`, and stops if not. It prints the librdkafka version and feature list.
4. Downloads the nginx source for the installed nginx version, if it is not already in `BUILD_DIR`.
5. Reads the flags the installed nginx was built with (`nginx -V`) and reuses them, plus `--with-compat`, so the module is binary compatible.
6. Compiles the module (macOS: and the njs module).
7. Checks the result is linked against librdkafka.
8. (With `--install`) Copies it into the modules directory.

The scripts do not edit `nginx.conf` and do not restart nginx.

## Output

| Item | Location |
|---|---|
| Built module | `~/nginx-build/nginx-<version>/objs/ngx_http_kafka_log_module.so` (macOS also builds `ngx_http_js_module.so`) |
| Configure log | `~/nginx-build/configure.log` |
| Build log | `~/nginx-build/make.log` |

Normal output is a few lines (nginx version, librdkafka version and features, `Built:`, `Installed:`). On failure, the last lines of the relevant log are printed along with the log path.

## Troubleshooting

| Message or symptom | Fix |
|---|---|
| `Confluent has no librdkafka repository for '<codename>'` | Your release is not supported by `--install-deps`. Install `librdkafka-dev` yourself (it must support SASL and SSL) and run without `--install-deps`. |
| `librdkafka ... does not support 'sasl'` (or `ssl`) | The installed librdkafka was built without that feature. Use Confluent's package (Linux) or Homebrew's (macOS). |
| `required tool not found: nginx` | Install nginx first. |
| Build fails with `-Werror` on a librdkafka header (Linux) | `EXTRA_CC_OPT=-Wno-error scripts/build-linux.sh --install` |
| nginx prints `module ... is not binary compatible` | The module was built for a different nginx version. Rebuild on the installed version. |
| `unknown directive "kafka_log_enable"` | The installed module was not built from this branch. Check `git branch --show-current`, rebuild with `--install`. |
| macOS: `nginx -t` prints `killed` | A module was copied over an existing file. Use `--install`, which deletes the old file first. |
