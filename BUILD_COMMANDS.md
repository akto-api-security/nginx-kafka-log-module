# Building and configuring the Akto nginx Kafka log module

This document explains how to build `ngx_http_kafka_log_module.so` from this repository, load it in nginx, and (optionally) connect to a Kafka broker that requires SASL authentication.

It supports the Akto nginx connector: https://docs.akto.io/traffic-connector/api-gateways/nginx

The SASL support comes from upstream pull request https://github.com/kaltura/nginx-kafka-log-module/pull/9 (`kafka_log_rdkafka_property`, `kafka_log_enable`). Build this repository from the branch that contains that change.

## 1. Status: what has and has not been tested

Read this before using anything below in production.

| Platform | Module code | Result |
|---|---|---|
| macOS arm64, Homebrew nginx 1.31.6, librdkafka 2.16.0 | PR #9 branch (commit `49cbc2b`) | Built and loaded. SASL/PLAIN over `SASL_PLAINTEXT`: correct password works, wrong password is rejected, traffic reaches the Akto dashboard. **Tested.** |
| Linux x86-64 (Ubuntu 22.04), nginx 1.30.x from nginx.org | upstream `master` (no SASL) | Built and loaded; publishing to Kafka observed. **Tested earlier.** |
| Linux x86-64 | PR #9 branch with SASL | **Not tested yet.** |
| `scripts/build-macos.sh`, `scripts/build-linux.sh` | n/a | Syntax-checked only. **Not yet run end to end.** |
| SCRAM, `SASL_SSL` / TLS, Kerberos, OAUTHBEARER | n/a | **Not tested.** The macOS librdkafka reports support for them; that is not the same as a working setup. |

## 2. Rules that decide whether a built module works

A dynamic module (`.so`) is tied to all of these. Build it on the machine type that will run it.

- **Operating system and C library.** A macOS build (Mach-O) does not load on Linux (ELF). A Debian (glibc) build does not load on Alpine (musl).
- **CPU architecture.** x86-64 and arm64 each need their own build.
- **nginx version and configure flags.** The source you compile against must be exactly the version that will load the module, configured with the same flags plus `--with-compat`. The scripts read the flags from `nginx -V`.
- **librdkafka.** The module links against it (`-lrdkafka`). It must be installed where the module will run, and it must support what you use (see section 7).

## 3. How this matches the Akto docs

| Akto docs (Ubuntu / Debian based) | Here |
|---|---|
| `apt install nginx-module-njs` | Section 5.1 (Linux). On macOS, njs is built from source by `scripts/build-macos.sh`. |
| Install the nginx-kafka-log-module "using nginx dynamic modules functionality" | Sections 4 and 5: exact build commands. The link in the Akto docs (nginx.com blog) now redirects to a general product page. |
| Save `api_log.js` as `/etc/nginx/njs/api_log.js` | Section 6.1 |
| `load_module /usr/lib/nginx/modules/ngx_http_js_module.so;` and the kafka module line | Section 6.2 |
| `subrequest_output_buffer_size`, `js_path`, `js_var`, `js_import`, `kafka_log_kafka_brokers`, `kafka_log_kafka_buffer_max_messages` in `http {}` | Section 6.3 |
| `js_body_filter ...` and `kafka_log kafka:akto.api.logs $responseBo;` in `server > location` | Section 6.4 |
| `nginx -s reload` | Section 6.5 |

Differences from the Akto docs when you use this repository's PR build:
1. `kafka_log_enable on;` is **required**. Without it the module sends nothing, silently.
2. `kafka_log_rdkafka_property <key> <value>;` is new and is how SASL settings are passed.
3. A rejected setting now fails `nginx -t`. Previously invalid values were ignored.

## 4. Build

Both scripts build the checked-out branch of this repository against the nginx that is installed on the machine. Check the branch first:

```
git branch --show-current
```

Neither script edits `nginx.conf`. Without `--install` they only build.

### 4.1 macOS (Homebrew nginx; tested on Apple Silicon only)

Prerequisites: `brew install nginx librdkafka`.

```
scripts/build-macos.sh              # build only
scripts/build-macos.sh --install    # build and install into $(brew --prefix)/etc/nginx/modules
```

What it does:
1. Checks librdkafka's features (`scripts/check-librdkafka.sh`).
2. Downloads the nginx source for the installed version and clones njs, into `~/nginx-build` (override with `BUILD_DIR`).
3. Runs `./configure` with Homebrew's own flags plus `--with-compat`, plus `-I<brew>/include`, `-L<brew>/lib` (so librdkafka is found) and `-Wno-error` (nginx's default `-Werror` stops on a warning inside librdkafka's own header).
4. Builds both `ngx_http_kafka_log_module.so` and `ngx_http_js_module.so`.
5. With `--install`, deletes the old files first and then copies the new ones. This matters on Apple Silicon: copying over an existing `.so` in place can make macOS kill nginx when it loads the module (`SIGKILL (Code Signature Invalid)`; `nginx -t` just prints `killed`).

Output files: `~/nginx-build/nginx-<version>/objs/ngx_http_kafka_log_module.so` and `.../ngx_http_js_module.so`.

### 4.2 Linux (Debian / Ubuntu, nginx from nginx.org)

Prerequisite: nginx and the njs module installed from the nginx.org packages (section 5.1).

```
scripts/build-linux.sh --install-deps --install
```

- `--install-deps` runs `apt-get install` for: `build-essential curl ca-certificates tar libpcre2-dev libpcre3-dev zlib1g-dev libssl-dev librdkafka-dev`.
- `--install` copies the module into the modules directory read from `nginx -V` (`--modules-path`, normally `/usr/lib/nginx/modules`), deleting the old file first.
- If a newer librdkafka header stops the build with a `-Werror` failure, run with `EXTRA_CC_OPT=-Wno-error`.

Output file: `~/nginx-build/nginx-<version>/objs/ngx_http_kafka_log_module.so`.

### 4.3 What the scripts run (manual equivalent)

```
cd ~/nginx-build/nginx-<version>
ARGS="$(nginx -V 2>&1 | sed -n 's/^configure arguments: //p')"
eval "./configure $ARGS --with-compat --add-dynamic-module=<path to this repository>"
make modules
```

Add `--add-dynamic-module=<njs source>/nginx` on macOS. On macOS also append the extra include and library flags described above to `--with-cc-opt` and `--with-ld-opt` inside `ARGS`.

The module's `config` file makes `./configure` look for `librdkafka/rdkafka.h`. When found it defines `NGX_HAVE_LIBRDKAFKA` and adds `-lrdkafka` to the link line. If it is not found, the Kafka code is compiled out and the build fails.

## 5. Linux: install nginx from nginx.org

The Akto docs assume the nginx.org packages (the `nginx-module-njs` package comes from there). Remove any distribution nginx first, because it conflicts:

```
sudo apt-get remove --purge -y nginx nginx-core nginx-common 'libnginx-mod-*'
```

Ubuntu (for Debian use `debian` instead of `ubuntu` in the repository line and install `debian-archive-keyring`):

```
sudo apt-get update
sudo apt-get install -y curl gnupg2 ca-certificates lsb-release ubuntu-keyring
curl -s https://nginx.org/keys/nginx_signing.key | gpg --dearmor | sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list
sudo apt-get update
apt-cache policy nginx-module-njs
sudo apt-get install -y nginx nginx-module-njs
nginx -v
```

Checks: `apt-cache policy nginx-module-njs` must show a candidate from `nginx.org`, and `nginx -v` must not say `(Ubuntu)`.

## 6. Configure nginx

| | macOS (Homebrew) | Linux (nginx.org packages) |
|---|---|---|
| Main config | `$(brew --prefix)/etc/nginx/nginx.conf` | `/etc/nginx/nginx.conf` |
| Server block | inside `nginx.conf` (no `conf.d/`) | `/etc/nginx/conf.d/default.conf` |
| Modules directory | `$(brew --prefix)/etc/nginx/modules` | `/usr/lib/nginx/modules` |
| njs script directory | `$(brew --prefix)/etc/nginx/njs` | `/etc/nginx/njs` |
| Restart | `brew services restart nginx` | `sudo systemctl restart nginx` |

Below, `<MODULES>` and `<NJS>` mean the directories in this table. Use absolute paths in `load_module`.

### 6.1 Akto's njs script

```
curl -o <NJS>/api_log.js https://raw.githubusercontent.com/akto-api-security/nginx-middleware/master/api_log.js
```

`api_log.js` builds one JSON record per request (path, headers, bodies, status, time, account id) and stores it in the nginx variable `$responseBo`. The C module reads that variable and sends its text as the Kafka message. The module does not parse the JSON.

### 6.2 Top of `nginx.conf`

```
load_module <MODULES>/ngx_http_js_module.so;
load_module <MODULES>/ngx_http_kafka_log_module.so;
```

### 6.3 Inside `http { ... }`

```
subrequest_output_buffer_size 8k;
js_path "<NJS>/";
js_var $responseBo "{}";
js_import main2 from api_log.js;
kafka_log_enable on;
kafka_log_kafka_brokers "<BROKER_HOST>:<PORT>";
kafka_log_kafka_buffer_max_messages 100000;
```

Optional: `kafka_log_kafka_compression none;`. The module defaults to snappy. It was needed on Apple Silicon because the Akto mini-runtime's JVM there had no snappy native library for that platform. The Akto docs do not set it.

### 6.4 In the `server` / `location` that proxies your application

```
location / {
    js_body_filter main2.to_lower_case buffer_type=buffer;
    kafka_log kafka:akto.api.logs $responseBo;
    # your existing proxy settings (proxy_pass ...)
}
```

`js_body_filter` and `kafka_log` are the two lines Akto's docs ask you to add. The function name `to_lower_case` is just the name inside `api_log.js`; it does not change case.

### 6.5 Check and restart

```
nginx -t
<restart command from the table>
ps -eo pid,lstart,command | grep "[n]ginx: master"
ps -eo pid,command | grep "[n]ginx: worker"
```

- `nginx -t` must pass.
- The master's start time must be recent. A restart that reports success can still leave nothing running.
- **At least one worker process must be listed.** See section 9, risk 1.

### 6.6 Adding SASL authentication

Change the broker address to the broker's SASL listener and add the settings. Do not repeat `kafka_log_enable`; setting it twice is an error.

```
kafka_log_kafka_brokers "<BROKER_HOST>:<SASL_PORT>";
kafka_log_rdkafka_property security.protocol SASL_PLAINTEXT;
kafka_log_rdkafka_property sasl.mechanism PLAIN;
kafka_log_rdkafka_property sasl.username <USER>;
kafka_log_rdkafka_property sasl.password <PASSWORD>;
```

Notes:
- The username and password must match what the broker has configured for that listener.
- `SASL_PLAINTEXT` sends the password unencrypted. For anything beyond a local test use `SASL_SSL` with the matching `ssl.*` properties (not tested here).
- nginx does not expand `$VARIABLES` or environment variables in these directives. The password must be in the file. Generate the file at deploy time (for example with `envsubst`) and restrict its permissions.
- Credentials are read when nginx starts. Changing the password requires a reload.

## 7. librdkafka requirements

`scripts/check-librdkafka.sh` prints the installed librdkafka's features and fails if `sasl`, `sasl_plain` or `ssl` is missing.

| You want | librdkafka needs |
|---|---|
| SASL/PLAIN | `sasl_plain` (built in) |
| `SASL_SSL` / TLS, SCRAM | `ssl` (OpenSSL at build time) and, for SCRAM, `sasl_scram` |
| Kerberos | `sasl_gssapi` (libsasl2 at build time) |
| OAUTHBEARER | `sasl_oauthbearer` |

Homebrew's librdkafka 2.16.0 reports `ssl, sasl_plain, sasl_scram, sasl_gssapi, sasl_oauthbearer`. For Linux, install a package built with SSL and SASL (check with the script) or build librdkafka from source after installing `libssl-dev` and `libsasl2-dev` (the development files of OpenSSL and Cyrus SASL).

## 8. Verify

Traffic reaching Kafka (all from the Kafka host; adjust the container name and broker):

```
docker exec <kafka-container> kafka-get-offsets --bootstrap-server localhost:29092 --topic akto.api.logs
curl -s -o /dev/null http://localhost/<some path that nginx proxies>
docker exec <kafka-container> kafka-get-offsets --bootstrap-server localhost:29092 --topic akto.api.logs
```

The offset must rise by 1 per request through nginx, and must not change for a request sent straight to the application.

Authentication:
- Correct credentials: no authentication errors in the nginx error log, and the offset rises.
- Wrong password: the offset does not move, and the error log repeats `SASL authentication error: Authentication failed: Invalid username or password` about once a second.

Read the last message to see what nginx sent:

```
docker exec <kafka-container> kafka-console-consumer --bootstrap-server localhost:29092 --topic akto.api.logs --partition 0 --offset <END_OFFSET_MINUS_1> --max-messages 1 --timeout-ms 5000
```

## 9. Known risks of the PR build

Risks 1 and 2 were reproduced in tests. The others are from reading the code or observing logs.

1. **A bad authentication setting can leave nginx with no workers.** Tested with `sasl.mechanism GSSAPI` on a librdkafka without that mechanism: the log shows `kafka_log: rd_kafka_new failed` and `worker process exited with fatal code 2 and cannot be respawned`. The master stays running with no workers, so nginx accepts connections and serves nothing. Always run `nginx -t`, restart, and confirm a worker process exists (section 6.5) before sending traffic.
2. **A rejected setting is logged together with its value.** Tested: `kafka_log_rdkafka_property fake.secret hunter2` prints `rd_kafka_conf_set failed [fake.secret] => [hunter2]: No such configuration property`. A mistyped key such as `sasl.passwrd` would print the real password into the terminal, CI logs or `error.log`.
3. **Wrong credentials lose data quietly.** Requests are not affected (sending happens after the response), nothing reaches Kafka, and the only sign is the repeating error line.
4. **Topic acknowledgements are disabled in the code** (`request.required.acks=0`, same as upstream `master`). A broker-side problem such as a missing write permission on the topic is not reported back.
5. **Messages queue in memory when Kafka is unreachable** (up to `queue.buffering.max.messages`, default 100000, then they are dropped).
6. **The module is off unless `kafka_log_enable on;` is set.** Configurations written for the Akto docs stop sending when moved to this build.
7. **Each worker creates its own producer and logs in separately.** More workers mean more broker connections.
8. **Credentials are plaintext in `nginx.conf`** and `SASL_PLAINTEXT` sends them unencrypted.
9. **PR #9 is open and unmerged upstream.** This repository is the maintained copy.

## 10. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Required feature not supported by broker` | You are connecting to the KRaft controller port. Use a client listener. |
| `use of undeclared identifier rd_kafka_topic_t` | librdkafka headers not found. macOS: `-I$(brew --prefix)/include` (the script adds it). |
| `'const' type qualifier ... -Werror` | `-Wno-error` (macOS script adds it; Linux: `EXTRA_CC_OPT=-Wno-error`). |
| `unknown directive "kafka_log"` | The kafka `load_module` line is missing or its path is wrong. |
| `unknown directive "kafka_log_enable"` | The installed module is not the PR build. Rebuild from this branch and reinstall. |
| `module ... is not binary compatible` | Built against a different nginx version or flags. Rebuild with the installed version. |
| `nginx -t` prints `killed` (macOS) | Module copied over an existing file. Delete the installed `.so` and copy again. Crash reports: `~/Library/Logs/DiagnosticReports/nginx-*.ips`. |
| Config changes have no effect | nginx was not restarted. Check the master's start time. |
| `"kafka_log_enable" directive is duplicate` | The directive appears twice in the config. |
| Offset never moves | `kafka_log_enable` missing, nginx not restarted, or publishing to a different Kafka than the one you read. |
| Consumer fails with `SnappyError` | Use `kafka_log_kafka_compression none;` and move the consumer group past old compressed messages. |
| `rd_kafka_conf_set failed [...]` at `nginx -t` | The property name or value is not accepted by this librdkafka. |

## 11. Before using this in production

- [ ] Run the Linux x86-64 test with the PR build and SASL (section 1 shows it has not been done).
- [ ] Run both scripts end to end on a clean machine.
- [ ] Confirm the librdkafka package on the target image reports the features you need (`scripts/check-librdkafka.sh`).
- [ ] Decide how the SASL password gets into the nginx configuration and who can read it.
- [ ] Use `SASL_SSL` and test it, if the network is not trusted.
- [ ] Add monitoring for: nginx worker count (risk 1) and a rising count of `kafka error` lines in the error log (risk 3).
- [ ] Update the Akto connector documentation for `kafka_log_enable`, the build commands and the SASL settings.
