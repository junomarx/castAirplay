# castAirplay

This is a command-line utility for casting audio to a specified AirPlay receiver on the network. Works with local files, local or remote .m3u/.pls playlists, or .m3u8 streams. Has the ability to loop a playlist. There is no title of the stream that is passed on to the receiver. Both versions support a statically built ffmpeg binary in the script's directory, for use on small/embedded systems.

Python (requires pyatv and ffmpeg) and shell script (ffmpeg, and cliraop required) versions available.

The target system to run this under is Linux.
