#!/bin/sh
# cf_ddns.sh - Cloudflare DDNS updater for ASUS routers (Asuswrt-Merlin),
# also usable on OpenWrt and any Linux.
#
# Runs on BusyBox ash. Needs only what the firmware ships: curl (HTTPS),
# sed, tr, head. No grep, jq, openssl or dig required (jq/jsonfilter are
# used if present).
#
# Usage:
#   cf_ddns.sh list              List DNS records of the zone that match CF_RECORD_NAME
#   cf_ddns.sh update [IP]       Update the record to IP (detected if omitted)
#   cf_ddns.sh check             Print detected IP and the record's current content
#   cf_ddns.sh verify            Verify that the API token is valid
#
# Exit codes: 0 ok / no change needed, 1 config error, 2 IP detection or
# network error, 3 Cloudflare API error.

## ----- Configuration -----
# Values come from (later wins): built-in defaults < config file < environment.
# Default config: first existing of the paths below.
if [ -z "${CF_CONFIG-}" ]; then
	for _c in /jffs/addons/cf_ddns/cf_ddns.conf /opt/etc/cf_ddns.conf \
		"$(dirname "$0")/cf_ddns.conf"; do
		[ -r "$_c" ] && { CF_CONFIG=$_c; break; }
	done
	CF_CONFIG=${CF_CONFIG:-/jffs/addons/cf_ddns/cf_ddns.conf}
fi

# Remember the environment so it can override the config file.
_env_token="${CF_API_TOKEN-}";     _env_zone="${CF_ZONE_NAME-}"
_env_zone_id="${CF_ZONE_ID-}";     _env_name="${CF_RECORD_NAME-}"
_env_type="${CF_RECORD_TYPE-}";    _env_proxied="${CF_PROXIED-}"
_env_ttl="${CF_TTL-}";             _env_create="${CF_CREATE_MISSING-}"
_env_ipurl="${CF_IP_URL-}";        _env_cache="${CF_CACHE_DIR-}"
_env_api="${CF_API_BASE-}";       _env_curl="${CF_CURL_OPTS-}"

CF_API_TOKEN=""            # Scoped API token with Zone:DNS:Edit on the zone
CF_ZONE_NAME=""            # e.g. example.com
CF_ZONE_ID=""              # optional; looked up from CF_ZONE_NAME and cached
CF_RECORD_NAME=""          # full name, e.g. www.example.com (or example.com)
CF_RECORD_TYPE="A"         # A or AAAA
CF_PROXIED="keep"          # true | false | keep (leave as is on update)
CF_TTL="1"                 # 1 = automatic, otherwise 60..86400
CF_CREATE_MISSING="false"  # create the record if it does not exist
CF_IP_URL=""               # IP echo service; default depends on record type
CF_CACHE_DIR="/tmp/cf_ddns"
CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_CURL_OPTS=""            # extra curl options, e.g. "--cacert /path/ca.crt"

# shellcheck source=/dev/null
[ -r "$CF_CONFIG" ] && . "$CF_CONFIG"

[ -n "$_env_token" ]   && CF_API_TOKEN="$_env_token"
[ -n "$_env_zone" ]    && CF_ZONE_NAME="$_env_zone"
[ -n "$_env_zone_id" ] && CF_ZONE_ID="$_env_zone_id"
[ -n "$_env_name" ]    && CF_RECORD_NAME="$_env_name"
[ -n "$_env_type" ]    && CF_RECORD_TYPE="$_env_type"
[ -n "$_env_proxied" ] && CF_PROXIED="$_env_proxied"
[ -n "$_env_ttl" ]     && CF_TTL="$_env_ttl"
[ -n "$_env_create" ]  && CF_CREATE_MISSING="$_env_create"
[ -n "$_env_ipurl" ]   && CF_IP_URL="$_env_ipurl"
[ -n "$_env_cache" ]   && CF_CACHE_DIR="$_env_cache"
[ -n "$_env_api" ]     && CF_API_BASE="$_env_api"
[ -n "$_env_curl" ]    && CF_CURL_OPTS="$_env_curl"

CF_QUIET="${CF_QUIET:-false}"
CF_DEBUG="${CF_DEBUG:-false}"

## ----- Logging -----
_log()   { [ "$CF_QUIET" = true ] || echo "* $*"; }
_debug() { [ "$CF_DEBUG" = true ] && echo "> $*" >&2; return 0; }
_err()   { echo "! $*" >&2; command -v logger >/dev/null 2>&1 && logger -t cf_ddns "$*"; return 0; }

die() { _code=$1; shift; _err "$@"; exit "$_code"; }

## ----- JSON helpers -----
# Cloudflare returns compact JSON. jq / jsonfilter are used when present;
# otherwise a tr/sed fallback (BusyBox-safe, no grep) extracts the first
# value of a key, which is sufficient for single-object lookups.
JSON_TOOL="${CF_JSON_TOOL:-}"
if [ -z "$JSON_TOOL" ]; then
	if command -v jq >/dev/null 2>&1; then JSON_TOOL=jq
	elif command -v jsonfilter >/dev/null 2>&1; then JSON_TOOL=jsonfilter
	else JSON_TOOL=sed
	fi
fi

# @1 JSON  @2 key inside .result[0] (or .result if it is an object)
json_result_field() {
	case "$JSON_TOOL" in
	jq)
		printf '%s' "$1" | jq -r --arg k "$2" \
			'.result | (if type == "array" then .[0] else . end) // {} | .[$k] // empty' ;;
	jsonfilter)
		printf '%s' "$1" | jsonfilter -q -e "@.result[0].$2" 2>/dev/null ||
			printf '%s' "$1" | jsonfilter -q -e "@.result.$2" ;;
	*)
		# Split on JSON punctuation into one "key":value per line, then pick
		# the first line for the key (after the "result" member).
		printf '%s' "$1" | sed 's/.*"result"://' | tr ',{}[]' '\n\n\n\n\n' |
			sed -n "s/^\"$2\":\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" | head -n 1 ;;
	esac
}

json_success() {
	case "$JSON_TOOL" in
	jq)         [ "$(printf '%s' "$1" | jq -r '.success')" = true ] ;;
	jsonfilter) [ "$(printf '%s' "$1" | jsonfilter -q -e '@.success')" = true ] ;;
	*)          case "$1" in *'"success":true'*|*'"success": true'*) return 0 ;; *) return 1 ;; esac ;;
	esac
}

json_errors() {
	case "$JSON_TOOL" in
	jq) printf '%s' "$1" | jq -r '.errors[]? | "\(.code): \(.message)"' 2>/dev/null ;;
	*)  printf '%s' "$1" | tr ',{}[]' '\n\n\n\n\n' | sed -n 's/^"message":"\(.*\)"$/\1/p' ;;
	esac
}

## ----- Validation -----
# Pure shell checks (no grep), safe on BusyBox ash.
is_ipv4() {
	case "$1" in ''|*[!0-9.]*|.*|*.|*..*) return 1 ;; esac
	_oldifs=$IFS; IFS=.
	# shellcheck disable=SC2086
	set -- $1
	IFS=$_oldifs
	[ $# -eq 4 ] || return 1
	for _o in "$@"; do
		case "$_o" in 0?*|????*) return 1 ;; esac
		[ "$_o" -le 255 ] || return 1
	done
}

is_ipv6() {
	# loose check: only hex digits and colons, at least two colons
	case "$1" in ''|*[!0-9A-Fa-f:]*) return 1 ;; *:*:*) return 0 ;; *) return 1 ;; esac
}

# Private / CGNAT / link-local IPv4 (e.g. ASUS WAN behind another router)
is_private_ipv4() {
	case "$1" in
	10.*|192.168.*|127.*|169.254.*) return 0 ;;
	172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
	100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
	esac
	return 1
}

is_valid_ip() {
	case "$CF_RECORD_TYPE" in
	A)    is_ipv4 "$1" ;;
	AAAA) is_ipv6 "$1" ;;
	*)    return 1 ;;
	esac
}

check_config() {
	[ -n "$CF_API_TOKEN" ]   || die 1 "CF_API_TOKEN is not set (config: $CF_CONFIG)"
	[ -n "$CF_ZONE_NAME" ] || [ -n "$CF_ZONE_ID" ] || die 1 "Set CF_ZONE_NAME or CF_ZONE_ID"
	[ -n "$CF_RECORD_NAME" ] || die 1 "CF_RECORD_NAME is not set"
	case "$CF_RECORD_TYPE" in A|AAAA) ;; *) die 1 "CF_RECORD_TYPE must be A or AAAA" ;; esac
	case "$CF_PROXIED" in true|false|keep) ;; *) die 1 "CF_PROXIED must be true, false or keep" ;; esac
	case "$CF_TTL" in ''|*[!0-9]*) die 1 "CF_TTL must be a number" ;; esac
}

## ----- HTTP -----
# @1 method  @2 path  [@3 JSON body]
# Prints the response body. The token is passed via a curl config on stdin
# so it does not appear in the process list.
cf_api() {
	_method=$1; _path=$2; _body=${3-}
	_debug "$_method $CF_API_BASE$_path ${_body}"
	if [ -n "$_body" ]; then
		printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" |
		curl $CF_CURL_OPTS --silent --show-error --connect-timeout 10 --max-time 30 \
			--config - -X "$_method" -H "Content-Type: application/json" \
			--data "$_body" "$CF_API_BASE$_path"
	else
		printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" |
		curl $CF_CURL_OPTS --silent --show-error --connect-timeout 10 --max-time 30 \
			--config - -X "$_method" "$CF_API_BASE$_path"
	fi
}

# Call API and require success. Result body in $_resp.
cf_api_ok() {
	_resp=$(cf_api "$@") || true
	if [ -z "$_resp" ]; then
		die 2 "No response from Cloudflare API ($1 $2)"
	fi
	if ! json_success "$_resp"; then
		_err "Cloudflare API error on $1 $2:"
		json_errors "$_resp" | while IFS= read -r line; do _err "  $line"; done
		_debug "$_resp"
		exit 3
	fi
}

## ----- IP detection -----
detect_ip() {
	_url="$CF_IP_URL"
	if [ "$CF_RECORD_TYPE" = AAAA ]; then
		_fam=-6; [ -n "$_url" ] || _url="https://[2606:4700:4700::1111]/cdn-cgi/trace"
	else
		_fam=-4; [ -n "$_url" ] || _url="https://1.1.1.1/cdn-cgi/trace"
	fi
	_out=$(curl $CF_CURL_OPTS "$_fam" --silent --connect-timeout 10 --max-time 20 "$_url") || return 1
	# cdn-cgi/trace returns "key=value" lines; other services return a bare IP.
	_ip=$(printf '%s\n' "$_out" | sed -n 's/^ip=//p' | head -n 1)
	[ -n "$_ip" ] || _ip=$(printf '%s\n' "$_out" | head -n 1 | tr -d ' \r')
	printf '%s' "$_ip"
}

## ----- Zone / record lookup -----
cache_file() { printf '%s/%s' "$CF_CACHE_DIR" "$1"; }

cache_read() { _f=$(cache_file "$1"); [ -r "$_f" ] && cat "$_f"; }

cache_write() {
	mkdir -p "$CF_CACHE_DIR" 2>/dev/null && chmod 700 "$CF_CACHE_DIR" 2>/dev/null
	printf '%s' "$2" > "$(cache_file "$1")" 2>/dev/null || true
}

get_zone_id() {
	[ -n "$CF_ZONE_ID" ] && return 0
	CF_ZONE_ID=$(cache_read "zone_${CF_ZONE_NAME}")
	[ -n "$CF_ZONE_ID" ] && return 0
	cf_api_ok GET "/zones?name=${CF_ZONE_NAME}"
	CF_ZONE_ID=$(json_result_field "$_resp" id)
	[ -n "$CF_ZONE_ID" ] || die 3 "Zone '$CF_ZONE_NAME' not found or token lacks access"
	cache_write "zone_${CF_ZONE_NAME}" "$CF_ZONE_ID"
}

# Sets REC_ID, REC_CONTENT, REC_PROXIED (empty if the record does not exist)
get_record() {
	cf_api_ok GET "/zones/${CF_ZONE_ID}/dns_records?type=${CF_RECORD_TYPE}&name=${CF_RECORD_NAME}"
	REC_ID=$(json_result_field "$_resp" id)
	REC_CONTENT=$(json_result_field "$_resp" content)
	REC_PROXIED=$(json_result_field "$_resp" proxied)
	_debug "record id=$REC_ID content=$REC_CONTENT proxied=$REC_PROXIED"
}

build_body() {
	_ip=$1; _proxied=$CF_PROXIED
	[ "$_proxied" = keep ] && _proxied=${REC_PROXIED:-false}
	printf '{"type":"%s","name":"%s","content":"%s","ttl":%s,"proxied":%s}' \
		"$CF_RECORD_TYPE" "$CF_RECORD_NAME" "$_ip" "$CF_TTL" "$_proxied"
}

## ----- Commands -----
cmd_verify() {
	[ -n "$CF_API_TOKEN" ] || die 1 "CF_API_TOKEN is not set"
	cf_api_ok GET "/user/tokens/verify"
	_log "Token is valid (status: $(json_result_field "$_resp" status))"
}

cmd_list() {
	check_config
	get_zone_id
	cf_api_ok GET "/zones/${CF_ZONE_ID}/dns_records?name=${CF_RECORD_NAME}"
	if [ "$JSON_TOOL" = jq ]; then
		printf '%s' "$_resp" | jq -r '.result[] | "\(.id)\t\(.type)\t\(.name)\t\(.content)\tproxied=\(.proxied)\tttl=\(.ttl)"'
	else
		printf '%s\n' "$_resp"
	fi
}

cmd_check() {
	check_config
	_ip=$(detect_ip) || die 2 "Could not detect public IP"
	get_zone_id
	get_record
	echo "detected: ${_ip:-<none>}"
	echo "record:   ${REC_CONTENT:-<missing>} (id ${REC_ID:-none})"
}

cmd_update() {
	check_config
	_ip=${1-}
	# ASUS passes its WAN IP; behind another router/CGNAT that is a private
	# address, so fall back to asking an external service.
	if [ "$CF_RECORD_TYPE" = A ] && [ -n "$_ip" ] && is_private_ipv4 "$_ip"; then
		_log "WAN IP $_ip is private (double NAT?), detecting public IP instead"
		_ip=""
	fi
	if [ -z "$_ip" ]; then
		_ip=$(detect_ip) || die 2 "Could not detect public IP"
	fi
	is_valid_ip "$_ip" || die 2 "Invalid $CF_RECORD_TYPE address: '$_ip'"
	_debug "IP: $_ip"

	# Fast path: nothing changed since our last successful update.
	_last_key="last_${CF_RECORD_TYPE}_${CF_RECORD_NAME}"
	if [ "$(cache_read "$_last_key")" = "$_ip" ] && [ "${CF_FORCE:-false}" != true ]; then
		_log "No change (cached), IP: $_ip"
		return 0
	fi

	get_zone_id
	get_record

	if [ -z "$REC_ID" ]; then
		[ "$CF_CREATE_MISSING" = true ] ||
			die 3 "Record $CF_RECORD_NAME ($CF_RECORD_TYPE) not found; set CF_CREATE_MISSING=true to create it"
		cf_api_ok POST "/zones/${CF_ZONE_ID}/dns_records" "$(build_body "$_ip")"
		_log "Created $CF_RECORD_NAME $CF_RECORD_TYPE -> $_ip"
	elif [ "$REC_CONTENT" = "$_ip" ]; then
		_log "No change, IP: $_ip"
	else
		cf_api_ok PATCH "/zones/${CF_ZONE_ID}/dns_records/${REC_ID}" "$(build_body "$_ip")"
		_log "Updated $CF_RECORD_NAME $CF_RECORD_TYPE: $REC_CONTENT -> $_ip"
	fi
	cache_write "$_last_key" "$_ip"
}

usage() {
	sed -n '2,15s/^# \{0,1\}//p' "$0"
}

main() {
	command -v curl >/dev/null 2>&1 || die 1 "curl is required"
	_cmd=${1:-list}
	[ $# -gt 0 ] && shift
	case "$_cmd" in
	list)    cmd_list ;;
	update|up) cmd_update "$@" ;;
	check)   cmd_check ;;
	verify)  cmd_verify ;;
	-h|--help|help) usage ;;
	*) usage; exit 1 ;;
	esac
}

main "$@"
