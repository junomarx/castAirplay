#!/usr/bin/env bash
# buildCliRaop.sh - build a patched, fully static 'cliraop' (AirPlay/RAOP sender, philippe44/libraop)
#
#   ./buildCliRaop.sh [--arch x86_64|aarch64|arm|armv6|x86] [--dynamic] [OUTPUT]
#
# Needs a glibc-based build machine (Debian/Ubuntu/Fedora/...) with git, make, gcc, g++ and the
# static C library (Debian/Ubuntu: libc6-dev, Fedora: glibc-static libstdc++-static).
# The result is fully static, so it also runs on musl systems (Alpine, Home Assistant OS
# add-ons, ...) and anything else with a Linux kernel - just copy it over.
# libraop ships its OpenSSL/codec/mDNS dependencies prebuilt for glibc, which is why the
# build itself can't run on musl.
#
# Cross-building, e.g. for a Raspberry Pi / HA Green on a PC:
#   sudo apt install g++-aarch64-linux-gnu && ./buildCliRaop.sh --arch aarch64 cliraop-aarch64
#
# Patches applied on top of upstream (pinned commit):
#   - fix -t (et) / -o (am) options, which upstream maps to the wrong fields -> MFi auth-setup
#     (needed by e.g. AirPort Express) was never triggered from the CLI
#   - no more 100% CPU busy-wait in the send loop
#   - clean TEARDOWN on SIGINT/SIGTERM (receiver is free again immediately)
#   - exit code 1 = cannot connect, 2 = connection to receiver lost, 0 = input ended
#   - numeric IPs are parsed without the system resolver (needed for static/musl use)
set -euo pipefail

COMMIT=70dffcd1b48c540c5d7ee063c54d6473ff86cbbb
ARCH=$(uname -m) STATIC=1 OUT=""

while (($#)); do
    case "$1" in
        --arch)    ARCH=$2; shift ;;
        --dynamic) STATIC=0 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         OUT=$1 ;;
    esac
    shift
done
OUT=${OUT:-"$(cd "$(dirname "$0")" && pwd)/cliraop"}

case "$ARCH" in
    x86_64|amd64)   PLATFORM=x86_64  TRIPLE=x86_64-linux-gnu ;;
    aarch64|arm64)  PLATFORM=aarch64 TRIPLE=aarch64-linux-gnu ;;
    armv7*|armhf|arm) PLATFORM=arm   TRIPLE=arm-linux-gnueabihf ;;
    armv6*)         PLATFORM=armv6   TRIPLE=arm-linux-gnueabihf ;;
    i?86|x86)       PLATFORM=x86     TRIPLE=i686-linux-gnu ;;
    *) echo "unsupported architecture $ARCH" >&2; exit 1 ;;
esac

if ldd --version 2>&1 | grep -qi musl || compgen -G "/lib/ld-musl-*" >/dev/null; then
    cat >&2 <<'MSG'
This is a musl system (Alpine, Home Assistant OS add-on, ...). libraop's bundled OpenSSL,
codec and mDNS libraries are prebuilt for glibc and can't be linked here.
Build on any glibc Linux machine (or VM/container) instead - the result is a static binary
that runs here unchanged:   ./buildCliRaop.sh [--arch aarch64] cliraop
MSG
    exit 1
fi

# native build, or cross compiler for another architecture
if [[ $PLATFORM == "$(uname -m | sed 's/amd64/x86_64/;s/arm64/aarch64/')" ]]; then
    CC=gcc CXX=g++ AR=ar
else
    CC=$TRIPLE-gcc CXX=$TRIPLE-g++ AR=$TRIPLE-ar
fi
for t in git make "$CC" "$CXX"; do
    command -v "$t" >/dev/null || { echo "missing build tool: $t" >&2; exit 1; }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo ">> fetching libraop @ ${COMMIT:0:7}"
git clone -q https://github.com/philippe44/libraop.git
cd libraop
git checkout -q "$COMMIT"
# top-level submodules only: libopenssl/libcodecs/libmdns ship prebuilt static libs
git submodule update -q --init crosstools curve25519 dmap-parser libcodecs libmdns libopenssl

echo ">> patching"
git apply <<'PATCH'
diff --git a/src/cliraop.c b/src/cliraop.c
index 0a74ad5..83b9836 100644
--- a/src/cliraop.c
+++ b/src/cliraop.c
@@ -10,6 +10,7 @@
 
 #include <stdio.h>
 #include <signal.h>
+#include <errno.h>
 #include <fcntl.h>
 #include <stdlib.h>
 #include <string.h>
@@ -157,6 +158,9 @@ static void close_platform(bool interactive) {
 
 /*----------------------------------------------------------------------------*/
 /*																			  */
+static volatile sig_atomic_t stop_requested = 0;
+static void on_signal(int sig) { stop_requested = 1; }
+
 /*----------------------------------------------------------------------------*/
 int main(int argc, char *argv[]) {
 	struct raopcl_s *raopcl;
@@ -178,7 +182,14 @@ int main(int argc, char *argv[]) {
 	bool interactive = false, alac = false, pairing = false;
 	char *secret = NULL, *md = NULL, *et = NULL, *am = NULL;
 	bool auth = false;
+	int rc = 0;
 	struct in_addr host = { INADDR_ANY };
+	struct sigaction sa = { 0 };
+
+	sa.sa_handler = on_signal;	// no SA_RESTART: a blocking read() on stdin gets interrupted
+	sigaction(SIGINT, &sa, NULL);
+	sigaction(SIGTERM, &sa, NULL);
+	signal(SIGPIPE, SIG_IGN);
 
 	for(i = 1; i < argc; i++){
 		if(!strcmp(argv[i],"-ntp")){
@@ -205,9 +216,9 @@ int main(int argc, char *argv[]) {
 		} else if (!strcmp(argv[i],"-m")) {
 			md = argv[++i];
 		} else if (!strcmp(argv[i], "-o")) {
-			md = argv[++i];
-		} else if(!strcmp(argv[i],"-t")) {
 			am = argv[++i];
+		} else if(!strcmp(argv[i],"-t")) {
+			et = argv[++i];
 		} else if (!strcmp(argv[i], "-u")) {
 			auth = true;
 		} else if (!strcmp(argv[i],"-a")) {
@@ -281,17 +292,21 @@ int main(int argc, char *argv[]) {
 	}
 
 	// get player's address
-	player.hostent = gethostbyname(player.name);
-	if (!player.hostent) {
-		LOG_ERROR("Cannot resolve name %s", player.name);
-		goto exit;
+	// numeric IP first: no resolver (NSS) needed, so a static build runs on musl/Alpine too
+	if (!inet_aton(player.name, &player.addr)) {
+		player.hostent = gethostbyname(player.name);
+		if (!player.hostent) {
+			LOG_ERROR("Cannot resolve name %s", player.name);
+			rc = 1;
+			goto exit;
+		}
+		memcpy(&player.addr.s_addr, player.hostent->h_addr_list[0], player.hostent->h_length);
 	}
 
-	memcpy(&player.addr.s_addr, player.hostent->h_addr_list[0], player.hostent->h_length);
-
 	// connect to player
 	if (!raopcl_connect(raopcl, player.addr, port, true)) {
 		LOG_ERROR("Cannot connect to AirPlay device %s:%hu, check firewall & port", inet_ntoa(player.addr), port);
+		rc = 1;
 		goto exit;
 	}
 
@@ -333,11 +348,25 @@ int main(int argc, char *argv[]) {
 			}
 		}
 
-		if (status == PLAYING && raopcl_accept_frames(raopcl)) {
+		if (stop_requested) break;
+
+		if (!raopcl_is_sane(raopcl) || !raopcl_is_connected(raopcl)) {
+			LOG_ERROR("connection to AirPlay device lost", NULL);
+			rc = 2;
+			break;
+		}
+
+		if (status == PLAYING && n && raopcl_accept_frames(raopcl)) {
 			n = read(infile, buf, DEFAULT_FRAMES_PER_CHUNK * 4);
-			if (!n)	continue;
+			if (n < 0) {
+				if (errno == EINTR) { n = -1; continue; }
+				n = 0;
+			}
+			if (!n) continue;
 			raopcl_send_chunk(raopcl, buf, n / 4, &playtime);
 			frames += n / 4;
+		} else {
+			usleep(5000);	// was a busy loop (100% CPU)
 		}
 
 		if (interactive && kbhit()) {
@@ -388,5 +417,5 @@ int main(int argc, char *argv[]) {
 exit:
 	raopcl_destroy(raopcl);
 	close_platform(interactive);
-	return 0;
+	return rc;
 }
PATCH

build() {  # build [LDFLAGS]
    # -Wno-unused-result: upstream ignores asprintf() results (only matters if malloc fails)
    # -Wno-cpp: crosstools includes <sys/poll.h>, which musl/newer libcs flag as deprecated
    CFLAGS="${CFLAGS:-} -Wno-unused-result -Wno-cpp" LDFLAGS="$1" \
        make -s STATIC=1 CC="$CC" CXX="$CXX" AR="$AR" PLATFORM="$PLATFORM" HOST=linux \
             -j"$(nproc 2>/dev/null || echo 2)" 2>&1 \
        | grep -v -e "statically linked applications requires at runtime" -e ": in function " || true
    [[ -x bin/cliraop-linux-$PLATFORM ]]
}

rm -f "bin/cliraop-linux-$PLATFORM"      # repo ships an (unpatched) prebuilt binary
echo ">> building for linux/$PLATFORM ($( ((STATIC)) && echo static || echo dynamic))"
if ((STATIC)) && ! build "-static"; then
    echo ">> static link failed (static libc missing? Fedora: dnf install glibc-static libstdc++-static)" >&2
    echo ">> falling back to a dynamic build - that one needs glibc on the target" >&2
    build ""
elif ((!STATIC)); then
    build ""
fi
[[ -x bin/cliraop-linux-$PLATFORM ]] || { echo "build failed" >&2; exit 1; }

install -m 755 "bin/cliraop-linux-$PLATFORM" "$OUT"
echo ">> done: $OUT ($(file -b "$OUT" 2>/dev/null | cut -d, -f1-2,4 || echo built))"
