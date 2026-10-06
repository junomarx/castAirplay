#!/usr/bin/env bash
# castAirplay.sh - stream a local file or internet radio to an AirPlay receiver. No Python needed.
#
#   castAirplay.sh [options] SOURCE DEVICE
#   castAirplay.sh --scan
#
# SOURCE  audio file, playlist (.m3u/.m3u8/.pls, local or http), HLS stream or any stream URL
# DEVICE  IP address, or the receiver's name (needs avahi-browse)
#
# Pipeline: ffmpeg (fetch + decode) -> raw PCM 44.1k/16/2 -> cliraop (RAOP sender) -> receiver
#
# Needs:    ffmpeg, cliraop (build with build-cliraop.sh), bash 4+
# Optional: avahi-browse (discovery, names, auto port/encryption), curl or wget (remote playlists)

set -uo pipefail

UA="airplay-cast/1.0"
VOLUME=50 PASSWORD="" PORT="" ET="" LATENCY_MS=2000 DEBUG=0
LOOP=0 RETRY=1 MAX_RETRIES=0 SCAN=0
RAOP_BIN="${CLIRAOP:-}"

log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  -v, --volume N        volume 0-100 (default 50)
  -p, --password PW     AirPlay password, if the receiver has one
  -P, --port N          RAOP port (default: from mDNS, else try 7000 then 5000)
      --et LIST         encryption types as in mDNS 'et' (default: from mDNS, else 0,4)
  -l, --latency MS      receiver buffer in ms (default 2000); higher = more robust radio
      --loop            repeat file/playlist forever
      --no-retry        don't reconnect live streams when they drop
      --max-retries N   give up after N failed attempts in a row (default 0 = never)
      --raop PATH       path to cliraop (default: $CLIRAOP, ./cliraop, PATH)
      --scan            list AirPlay receivers (needs avahi-browse)
  -d, --debug           verbose output from cliraop/ffmpeg
EOF
    exit "${1:-0}"
}

# ------------------------------------------------------------------------------ args
ARGS=()
while (($#)); do
    case "$1" in
        -v|--volume)   VOLUME=$2; shift ;;
        -p|--password) PASSWORD=$2; shift ;;
        -P|--port)     PORT=$2; shift ;;
        --et)          ET=$2; shift ;;
        -l|--latency)  LATENCY_MS=$2; shift ;;
        --loop)        LOOP=1 ;;
        --no-retry)    RETRY=0 ;;
        --max-retries) MAX_RETRIES=$2; shift ;;
        --raop)        RAOP_BIN=$2; shift ;;
        --scan)        SCAN=1 ;;
        -d|--debug)    DEBUG=1 ;;
        -h|--help)     usage 0 ;;
        --)            shift; ARGS+=("$@"); break ;;
        -*)            echo "unknown option $1" >&2; usage 1 ;;
        *)             ARGS+=("$1") ;;
    esac
    shift
done

# ------------------------------------------------------------------------------ mDNS (optional)
# avahi-browse -p output: =;iface;IPv4;name;type;domain;host;address;port;"txt" "txt" ...
unescape() {  # avahi escapes as \DDD (decimal), e.g. \064 = @, \032 = space
    local s=$1 out="" d
    while [[ $s =~ ^([^\\]*)\\([0-9]{3})(.*)$ ]]; do
        printf -v d "\\$(printf '%03o' "$((10#${BASH_REMATCH[2]}))")"
        out+="${BASH_REMATCH[1]}$d"; s=${BASH_REMATCH[3]}
    done
    printf '%s' "$out$s"
}

txt_get() {  # txt_get KEY "TXT RECORDS"
    [[ $2 =~ \"$1=([^\"]*)\" ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# prints: name<TAB>ip<TAB>port<TAB>txt   (one line per IPv4 RAOP service)
mdns_list() {
    command -v avahi-browse >/dev/null || return 1
    local name kind proto rawname addr port txt
    while IFS=';' read -r kind _ proto rawname _ _ _ addr port txt; do
        [[ $kind == "=" && $proto == "IPv4" && $addr != 127.* ]] || continue
        name=$(unescape "$rawname"); name=${name#*@}     # "MACADDR@Living Room" -> "Living Room"
        printf '%s\t%s\t%s\t%s\n' "$name" "$addr" "$port" "$txt"
    done < <(timeout 8 avahi-browse -rtp _raop._tcp 2>/dev/null) | sort -u
}

if ((SCAN)); then
    command -v avahi-browse >/dev/null || die "--scan needs avahi-browse (package avahi-utils)"
    printf '%-28s %-16s %-6s %-14s %s\n' NAME IP PORT MODEL ET
    mdns_list | while IFS=$'\t' read -r n a p t; do
        printf '%-28s %-16s %-6s %-14s %s\n' "$n" "$a" "$p" "$(txt_get am "$t")" "$(txt_get et "$t")"
    done
    exit 0
fi

((${#ARGS[@]} == 2)) || usage 1
SOURCE=${ARGS[0]} DEVICE=${ARGS[1]}

# ------------------------------------------------------------------------------ dependencies
command -v ffmpeg >/dev/null || die "ffmpeg not found"
raop_runs() {  # exit 126/127 = kernel/loader can't start it (wrong arch, or needs glibc on musl)
    "$1" -h >/dev/null 2>&1; local rc=$?; ((rc != 126 && rc != 127))
}
if [[ -z $RAOP_BIN ]]; then
    for c in "$(dirname "$0")/cliraop-$(uname -m)" "$(dirname "$0")/cliraop" \
             "./cliraop-$(uname -m)" "./cliraop" "$(command -v cliraop 2>/dev/null)"; do
        [[ -n $c && -x $c ]] || continue
        if raop_runs "$c"; then RAOP_BIN=$c; break; fi
        log "skipping $c: can't execute here (dynamically linked for glibc, or wrong CPU architecture)"
    done
fi
[[ -n $RAOP_BIN && -x $RAOP_BIN ]] || die "no usable cliraop - use the static cliraop-$(uname -m), or --raop PATH"
raop_runs "$RAOP_BIN" || die "$RAOP_BIN can't run on this system - use the static cliraop-$(uname -m)"

# ------------------------------------------------------------------------------ resolve device
IP="" TXT="" MPORT=""
if [[ $DEVICE =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IP=$DEVICE
    if entry=$(mdns_list | awk -F'\t' -v ip="$IP" '$2 == ip' | head -1) && [[ -n $entry ]]; then
        IFS=$'\t' read -r NAME _ MPORT TXT <<<"$entry"
    fi
else
    command -v avahi-browse >/dev/null || die "lookup by name needs avahi-browse - give the IP instead"
    entry=$(mdns_list | awk -F'\t' -v n="${DEVICE,,}" 'tolower($1) == n' | head -1)
    [[ -n $entry ]] || die "no AirPlay receiver named '$DEVICE' (try --scan)"
    IFS=$'\t' read -r NAME IP MPORT TXT <<<"$entry"
fi

# connection parameters: explicit option > mDNS TXT > defaults
[[ -n $PORT ]] && PORTS=("$PORT") || { [[ -n $MPORT ]] && PORTS=("$MPORT") || PORTS=(7000 5000); }
[[ -z $ET ]] && ET=$(txt_get et "$TXT")
# et unknown (no avahi): try plain first, then with MFi auth-setup (newer AirPort Express firmware
# wants it; some older receivers drop the connection when they get it)
if [[ -n $ET ]]; then ETS=("$ET"); else ETS=("0" "0,4"); fi
CANDS=(); for p in "${PORTS[@]}"; do for e in "${ETS[@]}"; do CANDS+=("$p $e"); done; done
[[ $(txt_get pw "$TXT") == true && -z $PASSWORD ]] && die "receiver requires a password (-p)"

RAOP_ARGS=(-v "$VOLUME" -l "$((LATENCY_MS * 441 / 10))" -d "$((DEBUG ? 6 : 1))")
[[ -n $PASSWORD ]] && RAOP_ARGS+=(-P "$PASSWORD")
am=$(txt_get am "$TXT"); [[ -n $am ]] && RAOP_ARGS+=(-o "$am")
md=$(txt_get md "$TXT"); [[ -n $md ]] && RAOP_ARGS+=(-m "$md")

log "Receiver: ${NAME:-$IP} ($IP, port ${PORTS[*]}, et=${ETS[*]})"

# AirPlay 1 needs the receiver to reach back to us (UDP timing/control). From a NAT'd container
# (Docker, Home Assistant add-on on 172.30.x.x) it can't, and the receiver silently never plays.
if command -v ip >/dev/null; then
    LOCAL_IP=$(ip route get "$IP" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
    if [[ -n $LOCAL_IP && ${LOCAL_IP%.*} != "${IP%.*}" && $LOCAL_IP =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
        log "WARNING: local address $LOCAL_IP is not on the receiver's network - if this runs in a"
        log "         container behind NAT (Docker, HA add-on), the receiver can't reach the timing"
        log "         port and will stay silent. Use host networking."
    fi
fi

# ------------------------------------------------------------------------------ resolve source
is_url() { [[ $1 =~ ^https?:// ]]; }

fetch() {
    if ! is_url "$1"; then cat -- "$1"
    elif command -v curl >/dev/null; then curl -fsSL --max-time 10 -A "$UA" -- "$1"
    elif command -v wget >/dev/null; then wget -q -T 10 -U "$UA" -O - -- "$1"
    else die "need curl or wget to read remote playlist $1"; fi
}

abs_entry() {  # make playlist entry $2 absolute relative to playlist $1
    local base=${1%%[?#]*} e=$2
    if is_url "$e"; then
        printf '%s' "$e"
    elif is_url "$base"; then
        if [[ $e == /* ]]; then
            [[ $base =~ ^(https?://[^/]+) ]]; printf '%s%s' "${BASH_REMATCH[1]}" "$e"
        else
            printf '%s/%s' "${base%/*}" "$e"
        fi
    elif [[ $e == /* ]]; then
        printf '%s' "$e"
    else
        printf '%s/%s' "$(cd "$(dirname "$base")" && pwd)" "$e"
    fi
}

resolve() {  # prints one playable entry per line
    local src=$1 depth=${2:-0} path text e
    path=${src%%[?#]*}; path=${path,,}
    if ((depth > 3)) || [[ ! $path =~ \.(m3u8?|pls)$ ]]; then printf '%s\n' "$src"; return; fi
    text=$(fetch "$src" | head -c 262144 | tr -d '\r') || die "cannot read playlist $src"
    if grep -q '#EXT-X-' <<<"$text"; then printf '%s\n' "$src"; return; fi   # HLS: ffmpeg handles it
    if [[ $path == *.pls ]]; then
        grep -iE '^File[0-9]+=' <<<"$text" | sed -E 's/^[Ff][Ii][Ll][Ee]([0-9]+)=/\1 /' \
            | sort -n | cut -d' ' -f2-
    else
        grep -vE '^[[:space:]]*(#|$)' <<<"$text"
    fi | while IFS= read -r e; do
        e=${e#"${e%%[![:space:]]*}"}; e=${e%"${e##*[![:space:]]}"}
        [[ -n $e ]] && resolve "$(abs_entry "$src" "$e")" $((depth + 1))
    done
}

mapfile -t SOURCES < <(resolve "$SOURCE")
((${#SOURCES[@]})) || die "nothing to play in $SOURCE"
LIVE=0; for s in "${SOURCES[@]}"; do is_url "$s" && LIVE=1; done
((DEBUG)) && printf '  -> %s\n' "${SOURCES[@]}" >&2

# ------------------------------------------------------------------------------ playback
TMP=$(mktemp -d)
FF_PID="" RP_PID="" STOP=0

cleanup() {
    [[ -n $RP_PID ]] && kill -TERM "$RP_PID" 2>/dev/null   # cliraop sends TEARDOWN
    [[ -n $FF_PID ]] && kill -TERM "$FF_PID" 2>/dev/null
    wait 2>/dev/null; rm -rf "$TMP"
}
trap 'STOP=1; log "Stopping."; cleanup; exit 0' INT TERM
trap 'rm -rf "$TMP"' EXIT

ffmpeg_cmd() {
    local src=$1
    FF=(ffmpeg -nostdin -hide_banner -loglevel "$( ((DEBUG)) && echo warning || echo error)")
    is_url "$src" && FF+=(-user_agent "$UA" -reconnect 1 -reconnect_streamed 1
                          -reconnect_on_network_error 1 -reconnect_delay_max 10)
    FF+=(-i "$src" -vn -map 0:a:0 -ac 2 -ar 44100 -f s16le pipe:1)
}

# play_one SRC -> 0 = input ended, 1 = connect failed, 2 = receiver lost, 3 = source failed
play_one() {
    local src=$1 rc ffrc i port et args
    for i in "${!CANDS[@]}"; do
        read -r port et <<<"${CANDS[$i]}"
        args=(-t "$et")
        [[ ,$et, != *,0,* && ,$et, == *,1,* ]] && args+=(-e)       # RSA-only receiver
        log "Playing $src"
        ffmpeg_cmd "$src"
        rm -f "$TMP/ff.pid" "$TMP/ff.rc"
        # plain pipe, so EOF propagates if ffmpeg dies; the subshell records ffmpeg's PID + exit code
        { "${FF[@]}" 2>"$TMP/ffmpeg.log" & echo $! > "$TMP/ff.pid"; wait $!; echo $? > "$TMP/ff.rc"; } |
            "$RAOP_BIN" "${RAOP_ARGS[@]}" "${args[@]}" -p "$port" "$IP" - 2>"$TMP/raop.log" &
        RP_PID=$!
        until [[ -s $TMP/ff.pid ]]; do sleep 0.05; done; FF_PID=$(<"$TMP/ff.pid")
        wait "$RP_PID"; rc=$?; RP_PID=""
        kill -TERM "$FF_PID" 2>/dev/null; FF_PID=""
        for _ in {1..50}; do [[ -s $TMP/ff.rc ]] && break; sleep 0.1; done
        ffrc=$(cat "$TMP/ff.rc" 2>/dev/null || echo 0)
        ((STOP)) && return 0
        if ((DEBUG)) || ((rc == 1 || rc == 2)); then              # show why cliraop gave up
            [[ -s $TMP/raop.log ]] && sed 's/^/  cliraop: /' "$TMP/raop.log" >&2
        fi
        if ((rc == 1 && ${#CANDS[@]} > 1)); then           # wrong port/et? try the next combination
            log "Connection failed (port $port, et=$et)"; continue
        fi
        ((rc == 1 || rc == 2)) || CANDS=("${CANDS[$i]}")   # remember the combination that worked
        if ((rc == 0 && ffrc != 0 && ffrc != 143 && ffrc != 255)) || ((DEBUG)); then
            [[ -s $TMP/ffmpeg.log ]] && sed 's/^/  ffmpeg: /' "$TMP/ffmpeg.log" >&2
            ((ffrc != 0 && ffrc != 143 && ffrc != 255)) && log "ffmpeg exited with $ffrc for $src"
        fi
        ((rc == 0 && ffrc != 0 && ffrc != 143 && ffrc != 255)) && return 3   # source failed
        return "$rc"
    done
    return 1
}

attempt=0
while :; do
    started=$SECONDS failed=0
    for src in "${SOURCES[@]}"; do
        play_one "$src"; rc=$?
        ((STOP)) && exit 0
        case $rc in
            1) log "Cannot connect to $IP"; failed=1; break ;;
            2) log "Connection to receiver lost"; failed=1; break ;;
            3) ((${#SOURCES[@]} == 1)) && failed=1 ;;          # playlist: just try next entry
        esac
    done
    ((SECONDS - started > 60)) && attempt=0                  # ran fine for a while: reset backoff
    if ((failed)); then
        ((LOOP || (LIVE && RETRY))) || exit 1
    elif ((LOOP)); then
        continue                                             # file/playlist done: start over
    elif ((LIVE && RETRY)); then
        log "Stream ended"                                   # radio dropped: reconnect
    else
        break                                                # file/playlist done
    fi
    attempt=$((attempt + 1))
    ((MAX_RETRIES && attempt > MAX_RETRIES)) && die "giving up after $MAX_RETRIES retries"
    delay=$((attempt < 5 ? 2 ** attempt : 30))
    log "Restarting in ${delay}s ..."
    sleep "$delay" & wait $!
done
