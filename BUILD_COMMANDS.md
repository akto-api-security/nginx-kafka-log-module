# Build and use the nginx Kafka log module

This repository builds `ngx_http_kafka_log_module.so`, the nginx module the Akto connector uses to send traffic to Kafka. This branch adds SASL authentication support (upstream pull request https://github.com/kaltura/nginx-kafka-log-module/pull/9).

Links:
- Akto nginx connector docs: https://docs.akto.io/traffic-connector/api-gateways/nginx
- How nginx dynamic modules are compiled: https://www.f5.com/company/blog/nginx/compiling-dynamic-modules-nginx-plus.html
- nginx `load_module`: https://nginx.org/en/docs/ngx_core_module.html#load_module
- nginx `configure` options: https://nginx.org/en/docs/configure.html
- njs (nginx JavaScript): https://nginx.org/en/docs/njs/

A built `.so` only works on the same operating system, CPU architecture and nginx version it was built for. Build it on the machine type that will run it.

## 1. Build

| Platform | Prerequisites | Command (run from the repository root) |
|---|---|---|
| macOS (Homebrew) | `brew install nginx librdkafka` ([nginx](https://formulae.brew.sh/formula/nginx), [librdkafka](https://formulae.brew.sh/formula/librdkafka)) | `scripts/build-macos.sh --install` |
| Debian / Ubuntu | nginx and `nginx-module-njs` from the nginx.org packages (next section) | `scripts/build-linux.sh --install-deps --install` |

### Linux only: install nginx and njs first

The build script does **not** install nginx or njs.

**1. Check what you already have.** If `nginx -v` shows an nginx.org version (no `(Ubuntu)` or `(Debian)` after it) and `/usr/lib/nginx/modules/ngx_http_js_module.so` exists, skip this section.

**2. Install from the official nginx.org packages** (what the Akto docs expect, `apt install nginx-module-njs`). Do not use a plain `sudo apt install nginx`: the distribution's nginx has no njs package. Official instructions: [Ubuntu](https://nginx.org/en/linux_packages.html#Ubuntu), [Debian](https://nginx.org/en/linux_packages.html#Debian). Ubuntu commands (for Debian, use `debian` instead of `ubuntu` in the repository line and install `debian-archive-keyring` instead of `ubuntu-keyring`):

```
sudo apt-get remove --purge -y nginx nginx-core nginx-common 'libnginx-mod-*'   # only if the distribution's own nginx is installed
sudo apt-get update
sudo apt-get install -y curl gnupg2 ca-certificates lsb-release ubuntu-keyring
curl -s https://nginx.org/keys/nginx_signing.key | gpg --dearmor | sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
gpg --dry-run --quiet --no-keyring --import --import-options import-show /usr/share/keyrings/nginx-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list
echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" | sudo tee /etc/apt/preferences.d/99nginx
sudo apt-get update
```

Install nginx:

```
sudo apt-get install -y nginx
nginx -v
```

Then install the njs module (a separate package from the same repository; install it after nginx so the versions match):

```
sudo apt-get install -y nginx-module-njs
ls /usr/lib/nginx/modules/ngx_http_js_module.so
```

- The `gpg --dry-run` line prints the key's fingerprint. It must contain `573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62`.
- The `echo "deb ..."` line adds the nginx.org repository (stable packages; the nginx.org page also shows a `mainline` variant). The `99nginx` line pins it, so apt prefers nginx.org's packages over the distribution's.
- After these steps, `apt-get install nginx` installs nginx.org's nginx instead of the distribution's. `nginx-module-njs` is a second package from the same repository.
- `nginx -v` must not say `(Ubuntu)`.

### What `--install-deps` installs (Linux)

`scripts/build-linux.sh --install-deps` runs `apt-get install` for the build tools and libraries, all from your distribution's own repositories:

| Package | Why |
|---|---|
| `build-essential` | C compiler and `make` |
| `curl`, `ca-certificates`, `tar` | download and unpack the nginx source |
| `libpcre2-dev`, `libpcre3-dev`, `zlib1g-dev`, `libssl-dev` | development files nginx's build needs (regex, compression, OpenSSL) |
| `librdkafka-dev` | the Kafka client library the module links against |

Before building, check you are on the right branch: `git branch --show-current`.

What the scripts do:
- Check that librdkafka supports SASL and SSL, and stop with an error if not. It prints the librdkafka version and feature list.
- Download the nginx source for the nginx version installed on the machine.
- Compile the module against it (on macOS they also compile the njs module).
- With `--install`, copy the `.so` into nginx's modules directory.

The scripts do not edit `nginx.conf`. Do that in step 2.

The built file is at `~/nginx-build/nginx-<version>/objs/ngx_http_kafka_log_module.so`.

## 2. Configure nginx

Follow the Akto docs for the `nginx.conf` changes (link above), with one addition: **`kafka_log_enable on;` is required**. Without it the module sends nothing.

Where the files are:

| | Linux (nginx.org packages) | macOS (Homebrew, Apple Silicon) |
|---|---|---|
| nginx.conf | `/etc/nginx/nginx.conf` | `/opt/homebrew/etc/nginx/nginx.conf` |
| Server block | `/etc/nginx/conf.d/default.conf` | inside `nginx.conf` |
| Modules | `/usr/lib/nginx/modules/` | `/opt/homebrew/etc/nginx/modules/` |
| njs script folder | `/etc/nginx/njs/` | `/opt/homebrew/etc/nginx/njs/` |
| Restart | `sudo systemctl restart nginx` | `brew services restart nginx` |

On an Intel Mac, replace `/opt/homebrew` with the output of `brew --prefix`.

Download Akto's script into the njs folder:

```
curl -o <njs folder>/api_log.js https://raw.githubusercontent.com/akto-api-security/nginx-middleware/master/api_log.js
```

Top of `nginx.conf` (use the modules folder from the table):

```
load_module <modules folder>/ngx_http_js_module.so;
load_module <modules folder>/ngx_http_kafka_log_module.so;
```

Inside `http { ... }`:

```
subrequest_output_buffer_size 8k;
js_path "<njs folder>/";
js_var $responseBo "{}";
js_import main2 from api_log.js;
kafka_log_enable on;
kafka_log_kafka_brokers "<broker host>:<port>";
kafka_log_kafka_buffer_max_messages 100000;
```

Inside the `location` that proxies your application:

```
js_body_filter main2.to_lower_case buffer_type=buffer;
kafka_log kafka:akto.api.logs $responseBo;
```

Then check and restart:

```
nginx -t
sudo systemctl restart nginx        # macOS: brew services restart nginx
ps -eo pid,command | grep "[n]ginx: worker"
```

`nginx -t` must pass, and **at least one worker process must be listed**.

## 3. Optional: SASL authentication

Point `kafka_log_kafka_brokers` at the broker's SASL listener and add:

```
kafka_log_rdkafka_property security.protocol SASL_PLAINTEXT;
kafka_log_rdkafka_property sasl.mechanism PLAIN;
kafka_log_rdkafka_property sasl.username <user>;
kafka_log_rdkafka_property sasl.password <password>;
```

- Any librdkafka setting can be passed this way. Property names: [librdkafka configuration reference](https://github.com/confluentinc/librdkafka/blob/master/CONFIGURATION.md). SASL overview: [Using SASL with librdkafka](https://github.com/confluentinc/librdkafka/wiki/Using-SASL-with-librdkafka). Broker side: [Kafka security documentation](https://kafka.apache.org/documentation/#security).
- The user and password must match the broker's configuration for that listener.
- `SASL_PLAINTEXT` sends the password unencrypted. Use `SASL_SSL` (with `ssl.*` properties) if the network is not trusted.
- nginx does not expand environment variables in these lines. The password goes into the file, so restrict who can read it.
- SASL/PLAIN works with a standard librdkafka. TLS and SCRAM need a librdkafka built with OpenSSL; the build scripts print what yours supports.

## 4. Check that it works

```
docker exec <kafka container> kafka-get-offsets --bootstrap-server localhost:29092 --topic akto.api.logs
curl -s -o /dev/null http://localhost/<a path nginx proxies>
docker exec <kafka container> kafka-get-offsets --bootstrap-server localhost:29092 --topic akto.api.logs
```

The offset rises by 1 for every request that goes through nginx. With a wrong password it does not move, and `error.log` shows `SASL authentication error`.

## 5. Things to know

- The module is **off unless `kafka_log_enable on;` is set**. Configs written for the Akto docs stop sending without it.
- If a SASL setting makes the Kafka client unable to start (for example an unsupported `sasl.mechanism`), nginx logs `kafka_log: rd_kafka_new failed` and the worker exits for good. nginx then runs with no workers and serves nothing. Always confirm a worker process exists after a restart.
- A rejected setting is logged with its value, so a mistyped key such as `sasl.passwrd` prints the real password.
- Wrong credentials do not break requests, but nothing reaches Kafka. Watch `error.log`.
- If a consumer fails with `SnappyError`, add `kafka_log_kafka_compression none;` (the module compresses with snappy by default).

## 6. Troubleshooting

| Symptom | Fix |
|---|---|
| `unknown directive "kafka_log_enable"` | The installed module was not built from this branch. Rebuild and reinstall. |
| `module ... is not binary compatible` | Built for a different nginx version. Rebuild on the installed version. |
| macOS: `nginx -t` prints `killed` | A module was copied over an existing file. Use `--install` (it deletes the old file first). |
| Offset never moves | `kafka_log_enable` missing, nginx not restarted, or you read a different Kafka than nginx writes to. |
| Build fails with `-Werror` on a librdkafka header (Linux) | Run `EXTRA_CC_OPT=-Wno-error scripts/build-linux.sh --install`. |
| `Required feature not supported by broker` | You are connecting to the KRaft controller port. Use a client listener. |
