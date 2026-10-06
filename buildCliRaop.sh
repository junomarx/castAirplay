#!/usr/bin/env bash
# buildCliRaop.sh - build a patched 'cliraop' (AirPlay/RAOP sender from philippe44/libraop)
#
# Needs: git, make, gcc, g++  (no pip, no root). OpenSSL & codecs come prebuilt from the repo.
# Result: ./cliraop next to this script (or path given as $1). The binary only links against
# libc/libstdc++, so you can build it once and copy it to other machines of the same arch.
#
# Patches applied on top of upstream (pinned commit):
#   - fix -t (et) / -o (am) options, which upstream maps to the wrong fields -> MFi auth-setup
#     (needed by e.g. AirPort Express) was never triggered from the CLI
#   - no more 100% CPU busy-wait in the send loop
#   - clean TEARDOWN on SIGINT/SIGTERM (receiver is free again immediately)
#   - exit code 1 = cannot connect, 2 = connection to receiver lost, 0 = input ended
set -euo pipefail

COMMIT=70dffcd1b48c540c5d7ee063c54d6473ff86cbbb
OUT=${1:-"$(cd "$(dirname "$0")" && pwd)/cliraop"}

case "$(uname -m)" in
    x86_64|amd64)   PLATFORM=x86_64 ;;
    aarch64|arm64)  PLATFORM=aarch64 ;;
    armv7*|armhf)   PLATFORM=arm ;;
    armv6*)         PLATFORM=armv6 ;;
    i?86)           PLATFORM=x86 ;;
    *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

for t in git make gcc g++; do
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
index 0a74ad5..cd75fc8 100644
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
@@ -284,6 +295,7 @@ int main(int argc, char *argv[]) {
 	player.hostent = gethostbyname(player.name);
 	if (!player.hostent) {
 		LOG_ERROR("Cannot resolve name %s", player.name);
+		rc = 1;
 		goto exit;
 	}
 
@@ -292,6 +304,7 @@ int main(int argc, char *argv[]) {
 	// connect to player
 	if (!raopcl_connect(raopcl, player.addr, port, true)) {
 		LOG_ERROR("Cannot connect to AirPlay device %s:%hu, check firewall & port", inet_ntoa(player.addr), port);
+		rc = 1;
 		goto exit;
 	}
 
@@ -333,11 +346,25 @@ int main(int argc, char *argv[]) {
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
@@ -388,5 +415,5 @@ int main(int argc, char *argv[]) {
 exit:
 	raopcl_destroy(raopcl);
 	close_platform(interactive);
-	return 0;
+	return rc;
 }
PATCH

echo ">> building for linux/$PLATFORM"
make -s STATIC=1 PLATFORM="$PLATFORM" HOST=linux -j"$(nproc 2>/dev/null || echo 2)" >/dev/null
install -m 755 "bin/cliraop-linux-$PLATFORM" "$OUT"
echo ">> done: $OUT"
