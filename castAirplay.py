#!/usr/bin/env python3
"""
airplay-cast.py - stream a local file or an internet radio stream to an AirPlay receiver.

    airplay-cast.py SOURCE DEVICE [options]

SOURCE  local audio file, local/remote playlist (.m3u, .m3u8, .pls),
        HLS stream (.m3u8) or any http(s)/icecast URL ffmpeg can open
DEVICE  IP address, device name (as shown by --scan) or pyatv identifier

Pipeline:  ffmpeg (fetch + decode anything) -> raw PCM 44.1k/16/2 -> pyatv (RAOP) -> receiver

Requirements:  ffmpeg,  pip install pyatv
"""

import argparse
import asyncio
import configparser
import ipaddress
import logging
import os
import signal
import subprocess
import time
import urllib.parse
import urllib.request

import pyatv
import pyatv.exceptions
import pyatv.protocols.raop as _raop
from pyatv.const import Protocol
from pyatv.interface import MediaMetadata
from pyatv.protocols.raop.audio_source import AudioSource

log = logging.getLogger("airplay-cast")


# Compat shim: some receivers (e.g. recent shairport-sync) answer GET /info with an
# empty 200 body, which makes pyatv crash. Treat that like "no /info support".
try:
    from pyatv.support import rtsp as _rtsp

    _orig_info = _rtsp.RtspSession.info

    async def _safe_info(self):
        try:
            return await _orig_info(self)
        except Exception as e:  # noqa: BLE001
            log.debug("Ignoring unparsable /info response: %s", e)
            return {}

    _rtsp.RtspSession.info = _safe_info
except Exception:  # pragma: no cover - pyatv internals changed, carry on without shim
    pass

PLAYLIST_EXT = (".m3u", ".m3u8", ".pls")
UA = "airplay-cast/1.0"


# --------------------------------------------------------------------------- source handling

def is_url(s: str) -> bool:
    return urllib.parse.urlparse(s).scheme in ("http", "https")


def read_text(src: str) -> str:
    if is_url(src):
        req = urllib.request.Request(src, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.read(256 * 1024).decode("utf-8", errors="replace")
    with open(src, encoding="utf-8", errors="replace") as f:
        return f.read()


def resolve(src: str, depth: int = 0) -> list[str]:
    """Turn SOURCE into a list of things ffmpeg can open directly."""
    path = urllib.parse.urlparse(src).path.lower() if is_url(src) else src.lower()
    if depth > 3 or not path.endswith(PLAYLIST_EXT):
        return [src]

    text = read_text(src)

    # HLS (.m3u8 with #EXT-X- tags): ffmpeg handles it natively
    if "#EXT-X-" in text:
        return [src]

    base = src if is_url(src) else os.path.dirname(os.path.abspath(src)) + os.sep
    entries = []
    if path.endswith(".pls"):
        cp = configparser.ConfigParser(interpolation=None, strict=False)
        cp.read_string(text)
        sec = next((s for s in cp.sections() if s.lower() == "playlist"), None)
        if sec:
            keys = sorted((k for k in cp[sec] if k.startswith("file")),
                          key=lambda k: int(k[4:] or 0))
            entries = [cp[sec][k].strip() for k in keys]
    else:
        entries = [l.strip() for l in text.splitlines()
                   if l.strip() and not l.lstrip().startswith("#")]

    out = []
    for e in entries:
        if not is_url(e) and not os.path.isabs(e):
            e = urllib.parse.urljoin(base, e) if is_url(base) else os.path.join(base, e)
        out.extend(resolve(e, depth + 1))
    if not out:
        raise ValueError(f"playlist {src} contains no entries")
    return out


def ffmpeg_cmd(src: str) -> list[str]:
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error"]
    if is_url(src):
        cmd += ["-user_agent", UA, "-reconnect", "1", "-reconnect_streamed", "1",
                "-reconnect_on_network_error", "1", "-reconnect_delay_max", "10"]
    cmd += ["-i", src, "-vn", "-map", "0:a:0",
            "-ac", "2", "-ar", "44100", "-f", "s16be", "pipe:1"]  # L16 = network byte order
    return cmd


def probe_duration(src: str) -> int:
    if is_url(src):
        return 0
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                              "-of", "csv=p=0", src], capture_output=True, text=True, timeout=10)
        return int(float(out.stdout.strip()))
    except Exception:  # noqa: BLE001
        return 0


class RawPCMSource(AudioSource):
    """Feeds ffmpeg's raw s16be/44.1k/stereo output straight into pyatv (no re-decoding).

    A background task keeps reading from the pipe into a buffer, so short network
    stalls of a radio stream are absorbed by the prebuffer instead of causing dropouts.
    """

    RATE, CHANNELS, SAMPLE_SIZE = 44100, 2, 2
    FRAME = CHANNELS * SAMPLE_SIZE

    def __init__(self, reader: asyncio.StreamReader, metadata: MediaMetadata, duration: int):
        self._reader = reader
        self._metadata = metadata
        self._duration = duration
        self._buf = bytearray()
        self._eof = False
        self._data = asyncio.Event()
        self._task = asyncio.ensure_future(self._fill())

    async def _fill(self):
        while True:
            chunk = await self._reader.read(65536)
            if not chunk:
                self._eof = True
                self._data.set()
                return
            self._buf += chunk
            self._data.set()

    async def prebuffer(self, seconds: float):
        want = int(seconds * self.RATE) * self.FRAME
        while len(self._buf) < want and not self._eof:
            self._data.clear()
            await self._data.wait()
        if not self._buf:
            raise RuntimeError("source produced no audio")

    async def readframes(self, nframes: int) -> bytes:
        need = nframes * self.FRAME
        while len(self._buf) < need and not self._eof:
            self._data.clear()
            await self._data.wait()
        n = min(need, len(self._buf)) // self.FRAME * self.FRAME
        out = bytes(self._buf[:n])
        del self._buf[:n]
        return out

    async def get_metadata(self) -> MediaMetadata:
        return self._metadata

    async def close(self) -> None:
        self._task.cancel()

    sample_rate = property(lambda self: self.RATE)
    channels = property(lambda self: self.CHANNELS)
    sample_size = property(lambda self: self.SAMPLE_SIZE)
    duration = property(lambda self: self._duration)


# Let pyatv's stream_file() accept our RawPCMSource as-is instead of running it through
# miniaudio (whose pipe/stream decoding is unreliable for endless radio streams).
_orig_open_source = _raop.open_source


async def _open_source(source, sample_rate, channels, sample_size):
    if isinstance(source, RawPCMSource):
        if (sample_rate, channels, sample_size) != (source.RATE, source.CHANNELS, source.SAMPLE_SIZE):
            raise RuntimeError(f"receiver wants {sample_rate}/{channels}ch/{sample_size * 8}bit")
        return source
    return await _orig_open_source(source, sample_rate, channels, sample_size)


_raop.open_source = _open_source


# --------------------------------------------------------------------------- AirPlay handling

async def find_device(target: str, timeout: int):
    loop = asyncio.get_running_loop()
    try:
        ipaddress.ip_address(target)
        is_ip = True
    except ValueError:
        is_ip = False

    found = []
    if is_ip:  # unicast query straight to the device - fast, works across VLANs
        found = await pyatv.scan(loop, hosts=[target], timeout=timeout)
    if not found:  # multicast scan, match by IP, name or identifier
        t = target.lower()
        found = [c for c in await pyatv.scan(loop, timeout=timeout)
                 if str(c.address) == target or c.name.lower() == t
                 or t in (i.lower() for i in c.all_identifiers)]
    found = [c for c in found if c.get_service(Protocol.RAOP)]
    if not found:
        raise SystemExit(f"No AirPlay (RAOP) receiver matching '{target}' found. Try --scan.")
    return found[0]


async def scan(timeout: int):
    for c in await pyatv.scan(asyncio.get_running_loop(), timeout=timeout):
        raop = c.get_service(Protocol.RAOP)
        if raop:
            print(f"{c.name:30} {str(c.address):16} id={c.identifier}  "
                  f"model={c.device_info.model_str}")


async def play_one(atv, src: str, title: str, prebuffer: float) -> int:
    """Stream a single source. Returns ffmpeg's exit code."""
    log.info("Playing %s", src)
    proc = await asyncio.create_subprocess_exec(
        *ffmpeg_cmd(src), stdout=asyncio.subprocess.PIPE)
    source = RawPCMSource(proc.stdout, MediaMetadata(title=title, artist="airplay-cast"),
                          probe_duration(src))
    try:
        await source.prebuffer(prebuffer if is_url(src) else 0.5)
        await atv.stream.stream_file(source)
    finally:
        await source.close()
        if proc.returncode is None:
            proc.terminate()
        rc = await proc.wait()
    return rc


async def run(args):
    sources = resolve(args.source)
    live = any(is_url(s) for s in sources)
    log.debug("Resolved to: %s", sources)

    conf = await find_device(args.device, args.timeout)
    if args.password:
        conf.get_service(Protocol.RAOP).password = args.password
    log.info("Receiver: %s (%s)", conf.name, conf.address)

    title = args.title or os.path.basename(urllib.parse.urlparse(args.source).path) or args.source
    attempt = 0
    while True:
        started = time.monotonic()
        atv = None
        try:
            atv = await pyatv.connect(conf, asyncio.get_running_loop())
            if args.volume is not None:
                await atv.audio.set_volume(args.volume)
            for src in sources:
                try:
                    rc = await play_one(atv, src, title, args.prebuffer)
                except RuntimeError as e:  # source produced nothing -> try next entry
                    log.warning("%s: %s", src, e)
                    continue
                if rc not in (0, -signal.SIGTERM):
                    log.warning("ffmpeg exited with %s for %s", rc, src)
        except (pyatv.exceptions.ConnectionLostError, pyatv.exceptions.ProtocolError,
                pyatv.exceptions.ConnectionFailedError, OSError, asyncio.TimeoutError) as e:
            log.warning("Stream interrupted: %s", e or type(e).__name__)
        finally:
            if atv:
                atv.close()
        if time.monotonic() - started > 60:  # ran fine for a while -> reset backoff
            attempt = 0

        # Files/playlists: done (unless --loop). Live streams: reconnect (unless --no-retry).
        if not (args.loop or (live and not args.no_retry)):
            break
        attempt += 1
        if args.max_retries and attempt > args.max_retries:
            raise SystemExit("Giving up after too many retries.")
        delay = min(30, 2 ** min(attempt, 5))
        log.info("Restarting in %ss ...", delay)
        await asyncio.sleep(delay)


def main():
    p = argparse.ArgumentParser(description="Stream a file or internet radio to an AirPlay receiver.")
    p.add_argument("source", nargs="?", help="file, playlist (.m3u/.m3u8/.pls) or stream URL")
    p.add_argument("device", nargs="?", help="receiver IP, name or identifier")
    p.add_argument("--scan", action="store_true", help="list AirPlay receivers and exit")
    p.add_argument("-v", "--volume", type=float, help="volume 0-100")
    p.add_argument("-p", "--password", help="AirPlay password, if the receiver has one")
    p.add_argument("-t", "--title", help="title shown on the receiver")
    p.add_argument("--loop", action="store_true", help="repeat file/playlist forever")
    p.add_argument("--no-retry", action="store_true", help="do not reconnect live streams")
    p.add_argument("--max-retries", type=int, default=0, help="0 = unlimited (default)")
    p.add_argument("--prebuffer", type=float, default=2.0,
                   help="seconds of a network stream to buffer before starting (default 2)")
    p.add_argument("--timeout", type=int, default=5, help="discovery timeout in seconds")
    p.add_argument("--debug", action="store_true")
    args = p.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    if not args.debug:
        logging.getLogger("pyatv").setLevel(logging.WARNING)
    if args.scan:
        asyncio.run(scan(args.timeout))
        return
    if not args.source or not args.device:
        p.error("SOURCE and DEVICE are required (or use --scan)")

    async def _main():
        # Ctrl-C / SIGTERM (e.g. systemd stop) -> cancel cleanly so ffmpeg and the
        # AirPlay session are torn down properly instead of being left dangling.
        task = asyncio.current_task()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, task.cancel)
        try:
            await run(args)
        except asyncio.CancelledError:
            log.info("Stopped.")

    asyncio.run(_main())


if __name__ == "__main__":
    main()
