# Cloudflare DDNS: analysis and design

## 1. What the existing tool does

`opt/bin/ali_ddns.sh` is a shell DDNS client for Alibaba Cloud DNS (Aliyun). It was written for routers running OpenWrt or Asuswrt-Merlin.

Flow when you run `ali_ddns.sh up`:

1. Ask a third-party service (`members.3322.org/dyndns/getip`) for the public IP.
2. Ask the provider's nameserver for the record's current value with `dig`.
3. If the two differ, build a signed `UpdateDomainRecord` request. The signature uses HMAC-SHA1 over sorted, URL-encoded query parameters, done with `openssl`. Then send the request with `curl`.

`jffs/scripts/ddns-start` hooks it into Merlin's "Custom DDNS". `jffs/scripts/firewall-start` and `Copy_of_gym.ipynb` have nothing to do with DDNS.

Most of the script's work is Aliyun's request signing: the parameter store, `rawurl_encode` and `calc_signature`. Cloudflare uses bearer tokens, so none of that code is needed.

## 2. Problems found in `ali_ddns.sh`

| # | Problem | Impact |
|---|---------|--------|
| 1 | `req_url` has no scheme (`alidns.aliyuncs.com/?...`), so curl uses **plain HTTP**. `-3` (SSLv3) is meaningless here and is an obsolete protocol anyway. | AccessKeyId and signed requests travel unencrypted. |
| 2 | The IP echo service is plain HTTP and its response is **not validated**. | A captive portal, error page or MITM response can be written into DNS as the "IP". |
| 3 | The current value comes from `dig +short`. | A CNAME chain or several A records give multi-line output, so the check never matches and the script updates on every run. Resolver caching can also hide a recent change. |
| 4 | `dig "$ns_param" ...` with an empty `DNSServer` passes `""` as an argument. | Odd behaviour when the "use default DNS" option is chosen. |
| 5 | API responses are never parsed. The script exits 0 whatever happened, and `ddns-start` always reports `ddns_custom_updated 1`. | Failures are silent and the router UI shows success. |
| 6 | Merlin passes the WAN IP as `$1` to `ddns-start`. The hook ignores it and asks an external service. | Extra dependency, and wrong when the router is double-NATed in a way the user didn't intend. |
| 7 | Credentials are hardcoded in the script body. | Easy to commit or leak; upgrades overwrite them. |
| 8 | The secret goes to `openssl -hmac` on the command line. | Visible in `ps` to other local users. |
| 9 | Not actually POSIX despite the README: `${string:pos:1}`, `==` inside `[ ]`, `echo -n`, `$((++i))`. | Breaks on dash, and `$((++i))` can loop forever there. Works on bash and BusyBox ash. |
| 10 | `put_param` uses `eval g_pval_$1=$2` with no quoting. | Values with spaces or shell metacharacters break the script or get executed. |
| 11 | `rawurl_encode` uses `printf "'$c"`, which encodes the code point, not UTF-8 bytes. | Wrong for non-ASCII values (rare here). |
| 12 | The `RecordId` must be found by hand and pasted in. IPv4 only. | Clumsy setup, no IPv6. |

## 3. Cloudflare version: goals

* **Primary target: ASUS routers on Asuswrt-Merlin**, using the firmware's BusyBox `ash` with no Entware or USB drive needed. Also runs on OpenWrt, dash and bash.
* **Only uses what the firmware ships:** `curl`, `sed`, `tr`, `head`. No `grep`, `jq`, `openssl`, `dig` or `wc`; IP checks are pure shell. `jq` or OpenWrt's `jsonfilter` is used when present, with a tr/sed fallback otherwise.
* Lives in `/jffs`, which survives reboots and firmware updates on ASUS routers.
* HTTPS everywhere, with a least-privilege API token.
* Fails loudly: meaningful exit codes, errors to stderr and syslog, and the Merlin hook reports failure.
* Zero manual ID lookup: the zone ID and record ID are resolved by name.
* A and AAAA records.

## 4. Design

### 4.1 Authentication

Cloudflare **API tokens** (`Authorization: Bearer <token>`), created with the "Edit zone DNS" template and scoped to a single zone. Don't use the legacy Global API Key with `X-Auth-Email` and `X-Auth-Key`: it gives full account access.

The token is fed to curl through `--config -` on stdin, so it never appears in the process list.

### 4.2 API calls

| Step | Request |
|------|---------|
| Verify token | `GET /user/tokens/verify` |
| Zone ID (cached to disk) | `GET /zones?name=<zone>` |
| Find record | `GET /zones/{zone}/dns_records?type=A&name=<fqdn>` |
| Update | `PATCH /zones/{zone}/dns_records/{id}` with `{"type","name","content","ttl","proxied"}` |
| Create (opt-in) | `POST /zones/{zone}/dns_records` |

Each response is checked for `"success":true`, and the `errors[].message` values are reported.

### 4.3 Deciding whether to update

Comparing against `dig` doesn't work for Cloudflare. A **proxied** record (orange cloud) resolves to Cloudflare edge IPs, never to your IP, so a `dig` check would update on every run. The design uses two levels instead:

1. **Local cache** (`$CF_CACHE_DIR/last_<type>_<name>`, in `/tmp` by default so it is lost on reboot). If the detected IP equals the last IP successfully pushed, exit with no network call to Cloudflare. This makes running from cron every minute cheap.
2. **API truth.** Otherwise read the record through the API and PATCH only if `content` differs.

The cost: if someone edits the record by hand in the dashboard, the cache hides it until the IP changes or a reboot clears `/tmp`. `CF_FORCE=true` skips the cache.

### 4.4 Public IP detection

In order of preference:

The device running the script often doesn't have the public IP on its own interface. For example, it sits behind an ISP gateway that can't run custom scripts. So detecting the IP with `curl` is the main path, as in `ali_ddns.sh`:

1. If an IP is given as an argument and it's public, use it. The Merlin hook passes the WAN IP as `$1`. A private or CGNAT address (10/8, 172.16/12, 192.168/16, 100.64/10) is ignored, and the script falls through to detection.
2. Otherwise try the services in `CF_IP_URLS` in order, with `curl -4` or `-6`, and take the **first answer that is a valid public IP**. A service that times out, returns an HTML or error page, or returns a private address is skipped. The defaults are:
   * A: `https://1.1.1.1/cdn-cgi/trace`, then `http://members.3322.org/dyndns/getip` (the service `ali_ddns.sh` uses, and reachable from mainland China), then `https://api.ipify.org`, then `https://icanhazip.com`.
   * AAAA: `https://[2606:4700:4700::1111]/cdn-cgi/trace`, then `https://api6.ipify.org`, then `https://ipv6.icanhazip.com`.

   A service can return a bare IP or `ip=…` lines (Cloudflare's trace format). `CF_IP_URL` from older configs is still accepted as a one-item list.

The IP is detected once per run and shared by all the records being updated.

### 4.5 Configuration

The order is built-in defaults, then the config file (sourced, should be `chmod 600`), then environment variables. The config file is the first that exists of `/jffs/addons/cf_ddns/cf_ddns.conf`, `/opt/etc/cf_ddns.conf`, and `cf_ddns.conf` next to the script; `CF_CONFIG` overrides it. Any later source overrides an earlier one. Keeping config out of the script means upgrades don't overwrite credentials. See `opt/etc/cf_ddns.conf.example`.

`CF_PROXIED=keep` (the default) keeps the record's current proxy setting, so a DDNS update never accidentally turns the orange cloud on or off.

### 4.6 Commands, arguments and exit codes

```
cf_ddns.sh                          list records for CF_RECORD_NAME
cf_ddns.sh up|update [NAME...] [IP] update record(s)
cf_ddns.sh NAME... [IP]             same as update
cf_ddns.sh list  [NAME]
cf_ddns.sh check [NAME]             detected public IP vs the record's value
cf_ddns.sh verify                   check the API token
```

**Record names.** `NAME` is a subdomain of `CF_ZONE_NAME`, the same idea as `DomainRR` in `ali_ddns.sh`:

| Argument | Record updated (zone `example.com`) |
|----------|-------------------------------------|
| `www` | `www.example.com` |
| `home.lab` | `home.lab.example.com` |
| `@` | `example.com` |
| `www.example.com` | `www.example.com` (already a full name) |
| `nas.other.org.` | `nas.other.org` (trailing dot means absolute) |

With no name, `CF_RECORD_NAME` from the config is used. Several names can be updated in one run (`cf_ddns.sh up www nas @`). A failure on one name doesn't stop the others; the exit code is the worst result. An argument made of digits and dots, or containing `:`, is taken as an IP and validated, so a mistyped IP is never turned into a record name.

**Compatibility with `ali_ddns.sh`:**

| Call | `ali_ddns.sh` | `cf_ddns.sh` |
|------|---------------|--------------|
| no arguments | list records | list records |
| `up` | update | update |
| any other argument | update (the argument is ignored) | update, and the argument is the record name |

Existing crontab entries and `ddns-start` calls (`… up`) therefore work unchanged.

| Exit code | Meaning |
|------|---------|
| 0 | Updated, or no change needed |
| 1 | Configuration error |
| 2 | IP detection or network failure, or invalid IP |
| 3 | Cloudflare API error, or record missing |

The Merlin hook (`jffs/scripts/ddns-start.cloudflare`) maps these to `ddns_custom_updated 1` or `0`.

### 4.7 Deployment

* **ASUS (Asuswrt-Merlin)**. Stock ASUS firmware can't run custom scripts, so Merlin is required.
  1. Administration → System: set *Enable JFFS custom scripts and configs* to **Yes**.
  2. Enable SSH and log in, then:
     ```sh
     mkdir -p /jffs/addons/cf_ddns
     # copy jffs/scripts/cf_ddns.sh            -> /jffs/scripts/cf_ddns.sh
     # copy jffs/scripts/ddns-start.cloudflare -> /jffs/scripts/ddns-start
     # copy the config example                 -> /jffs/addons/cf_ddns/cf_ddns.conf, then edit it
     chmod 755 /jffs/scripts/cf_ddns.sh /jffs/scripts/ddns-start
     chmod 600 /jffs/addons/cf_ddns/cf_ddns.conf
     /jffs/scripts/cf_ddns.sh verify && /jffs/scripts/cf_ddns.sh check
     ```
  3. WAN → DDNS: Server = **Custom**, Host Name = your record name, Apply. The router now calls the hook whenever the WAN IP changes.
  4. Optional safety net with cron: `cru a cf_ddns "*/15 * * * * /jffs/scripts/cf_ddns.sh update"`. To keep it across reboots, put that line in `/jffs/scripts/services-start`.
  5. If curl reports a certificate error, point `CF_CURL_OPTS="--cacert <bundle>"` at a CA bundle stored on `/jffs`.
* **OpenWrt:** add to cron: `*/5 * * * * /opt/bin/cf_ddns.sh update >/dev/null 2>&1`. Optionally also run it from `/etc/hotplug.d/iface/` on `ifup`.
* **Any Linux:** cron or a systemd timer, same command.

### 4.8 Not done yet (possible extensions)

* Several records per run, for example a list of names or A and AAAA together. Today you need one config per record, set with `CF_CONFIG=...`.
* Updating every record in the zone that shares the old IP.
* Retry with backoff on HTTP 429 or 5xx. Today the run fails and the next cron run retries.

## 5. Testing

The script was exercised against a local mock of the Cloudflare v4 API under **BusyBox ash** (v1.36, with only `curl` and BusyBox tools on `PATH`), **dash** and **bash**, with both the jq and the sed JSON back ends. IP validation was also checked: private and CGNAT WAN IPs fall back to detection, and `256.1.1.1`, `01.2.3.4`, `1.2.3` and an IPv4 address for an AAAA record are all rejected. The service fallback was tested with a chain of a dead host, an HTML page, a private IP and then a bare IP; the bare IP was used, and a chain with no usable answer exits with code 2. Arguments tested: no arguments, `up`, any other argument, `@`, multi-level names, full names, several names in one run, and a name containing shell characters (rejected). The cases were: token verify (valid and invalid), list, detect and update, the cached no-op, invalid-IP rejection, a missing record (error, then create with `CF_CREATE_MISSING`), and `proxied` preservation on PATCH.

It hasn't been run on a real ASUS router (whose BusyBox version and curl build vary by model), against the real Cloudflare API, or with `jsonfilter`. A first real run should use `verify`, then `check`, before `update`.
