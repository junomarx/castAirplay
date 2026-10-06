# castAirplay

This is a command-line utility for casting audio to a specified AirPlay receiver on the network. Works with local files, local or remote .m3u/.pls playlists, or .m3u8 streams. Has the ability to loop a playlist. There is no title of the stream that is passed on to the receiver. 

Python (requires pyatv and ffmpeg) and shell script (ffmpeg, and cliraop required) versions available. Both versions support a statically built ffmpeg binary in the script's directory, for use on small/embedded systems. Special provisions for Home Assistant (main motivation in creating this utility), the shell version will perform a system detection routine; if Home Assistant is detected, it will check if ffmpeg is available, and if not, install it.

The target system to run this under is Linux. 

Optional switches: <br>
  -v, --volume N        volume 0-100 (default 50) <br>
  -p, --password PW     AirPlay password, if the receiver has one <br>
  -P, --port N          RAOP port (default: from mDNS, else try 7000 then 5000) <br>
      --et LIST         encryption types as in mDNS 'et' (default: from mDNS, else 0,4) <br>
  -l, --latency MS      receiver buffer in ms (default 2000); higher = more robust radio <br>
      --loop            repeat file/playlist forever <br>
      --no-retry        don't reconnect live streams when they drop <br>
      --max-retries N   give up after N failed attempts in a row (default 0 = never) <br>
      --raop PATH       path to cliraop (default: $CLIRAOP, ./cliraop, PATH) <br>
      --scan            list AirPlay receivers (needs avahi-browse) <br>
  -d, --debug           verbose output from cliraop/ffmpeg <br>
