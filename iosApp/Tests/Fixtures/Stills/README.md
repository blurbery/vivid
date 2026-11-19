# Keyframe still fixtures

These files are test input for `KeyframeStillReaderTests`.
They were generated with FFmpeg's own test pattern, so they hold no third-party content.
Each is eight seconds of `testsrc2` at 320 by 180 and 24 frames a second with a keyframe every two seconds, apart from the rotated one.
A 64 pixel square in the top left corner is red, green, blue and then white, one colour for each two seconds, so a test can tell which keyframe it was given.

The commands share this pattern, shown here as `$SRC`:

```sh
SRC="testsrc2=size=320x180:rate=24:duration=8,drawbox=w=64:h=64:t=fill:c=red:enable='lt(t,2)',drawbox=w=64:h=64:t=fill:c=lime:enable='between(t,2,3.999)',drawbox=w=64:h=64:t=fill:c=blue:enable='between(t,4,5.999)',drawbox=w=64:h=64:t=fill:c=white:enable='gte(t,6)'"
```

`stills_h264_bframes.mkv` is H.264 in Matroska with B-frames:

```sh
ffmpeg -f lavfi -i "$SRC" -c:v libx264 -preset medium -b:v 240k -g 48 -keyint_min 48 -sc_threshold 0 -bf 2 -pix_fmt yuv420p -bsf:v filter_units=remove_types=6 -map_metadata -1 -fflags +bitexact -flags:v +bitexact stills_h264_bframes.mkv
```

`stills_h264_bframes.mp4` is the same video in MP4 with its index at the front:

```sh
ffmpeg -f lavfi -i "$SRC" -c:v libx264 -preset medium -b:v 240k -g 48 -keyint_min 48 -sc_threshold 0 -bf 2 -pix_fmt yuv420p -bsf:v filter_units=remove_types=6 -movflags +faststart -map_metadata -1 -fflags +bitexact -flags:v +bitexact stills_h264_bframes.mp4
```

`stills_hevc10_pq_opengop.mkv` is 10-bit HEVC in Matroska with B-frames and open groups of pictures, tagged as PQ with BT.2020 primaries:

```sh
ffmpeg -f lavfi -i "$SRC,format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv" -c:v libx265 -preset medium -b:v 240k -x265-params "keyint=48:min-keyint=48:scenecut=0:bframes=3:open-gop=1:info=0:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:log-level=error" -pix_fmt yuv420p10le -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv -map_metadata -1 -fflags +bitexact -flags:v +bitexact stills_hevc10_pq_opengop.mkv
```

`stills_h264_rotated.mp4` is two seconds at 160 by 90 with a red 40 pixel square in the top left corner, marked to be shown turned a quarter turn anticlockwise:

```sh
ffmpeg -f lavfi -i "testsrc2=size=160x90:rate=24:duration=2,drawbox=w=40:h=40:t=fill:c=red" -c:v libx264 -preset medium -b:v 150k -g 24 -pix_fmt yuv420p -bsf:v filter_units=remove_types=6 -map_metadata -1 -fflags +bitexact -flags:v +bitexact rotated_source.mp4
ffmpeg -display_rotation 90 -i rotated_source.mp4 -c copy -map_metadata -1 -fflags +bitexact stills_h264_rotated.mp4
```

The `filter_units` step drops the encoder's own information message from the H.264 files.
The files were made with FFmpeg 9 built with libx264 and libx265.
A different encoder version gives different bytes, so the keyframe sizes the tests expect are read from the files, not written into the tests.
