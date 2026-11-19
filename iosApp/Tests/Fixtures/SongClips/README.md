# Song identification fixtures

These files are test input for `SongIdentificationTests`.
They were generated with FFmpeg's own test pattern and tone generators, so they hold no third-party content.

The commands share these settings, shown here as `$V` and `$BE`:

```sh
V="testsrc2=size=160x90:rate=12:duration=6"
BE="-map_metadata -1 -fflags +bitexact -flags:v +bitexact -flags:a +bitexact"
```

`songclip_ac3_51_centre.mkv` is six seconds of 5.1 AC-3 in Matroska.
The front left and right channels carry a 440 Hz tone and the centre channel a 1 kHz tone, so a test can tell whether the centre channel made it into a mix:

```sh
ffmpeg -f lavfi -i "$V" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=6" -filter_complex "[1][1][2]amerge=inputs=3,pan=5.1|FL=c0|FR=c1|FC=c2|LFE=0*c0|BL=0*c0|BR=0*c0[a]" -map 0:v -map "[a]" -c:v libx264 -preset medium -g 12 -b:v 40k -pix_fmt yuv420p -bsf:v filter_units=remove_types=6 -c:a ac3 -b:a 192k $BE songclip_ac3_51_centre.mkv
```

`songclip_aac_stereo.mp4` is six seconds of a 440 Hz tone as 44.1 kHz stereo AAC in MP4, for the conversion to 48 kHz and AAC's start-up delay:

```sh
ffmpeg -f lavfi -i "$V" -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=6" -c:v libx264 -preset medium -g 12 -b:v 40k -pix_fmt yuv420p -bsf:v filter_units=remove_types=6 -c:a aac -b:a 64k -ac 2 -movflags +faststart $BE songclip_aac_stereo.mp4
```

`songclip_flac_two_tracks.mkv` has two FLAC sound tracks: a 440 Hz tone that starts one second in, then a 1 kHz tone from the start.
It checks that the track asked for is the one read, and that times are on the player's clock:

```sh
ffmpeg -f lavfi -i "$V" -itsoffset 1 -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=5" -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=6" -map 0:v -map 1:a -map 2:a -c:v libx264 -preset medium -g 12 -b:v 40k -pix_fmt yuv420p -bsf:v filter_units=remove_types=6 -c:a flac $BE songclip_flac_two_tracks.mkv
```

`songclip_flac_gap.mkv` has nine seconds of picture and a 440 Hz FLAC tone with a gap in its timestamps: two seconds of sound, then nothing until seven seconds in, then two more.
It checks that a clip ends at a gap rather than joining the sound on either side:

```sh
ffmpeg -f lavfi -i "testsrc2=size=160x90:rate=12:duration=9" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=4" -filter_complex "[1]asetpts='PTS+if(gte(T,2),5/TB,0)'[a]" -map 0:v -map "[a]" -c:v libx264 -preset medium -g 12 -b:v 30k -pix_fmt yuv420p -bsf:v filter_units=remove_types=6 -c:a flac $BE songclip_flac_gap.mkv
```

`songclip_melody.mkv` is twenty seconds of made-up music beside a test pattern, as stereo AAC: eleven seconds of one tune, `$A`, then the first nine seconds of another, `$B`.
`songclip_melody_reference.m4a` is twenty seconds of `$B` on its own, from which the tests make a custom ShazamKit catalogue, so identification is tested without reaching Shazam.
Asked about nine seconds in, the first six-second step (five to eleven seconds) holds only `$A` and can't match, and the second step reaches into `$B` and does, which checks that a clip is lengthened when the first try finds nothing:

```sh
A="aevalsrc=exprs='0.25*sin(2*PI*t*(250+11*mod(floor(t*8)*floor(t*8)*5+1\,83)))+0.2*sin(2*PI*t*(700+7*mod(floor(t*8)*13\,67)))+0.15*sin(2*PI*t*(1300+19*mod(floor(t*8)*3+floor(t*8)*floor(t*8)\,59)))':s=44100:d=11"
B="aevalsrc=exprs='0.25*sin(2*PI*t*(220+9*mod(floor(t*8)*floor(t*8)*7+3\,89)))+0.2*sin(2*PI*t*(660+13*mod(floor(t*8)*11+floor(t*8)*floor(t*8)\,71)))+0.15*sin(2*PI*t*(1500+17*mod(floor(t*8)*5\,53)))':s=44100:d=20"
ffmpeg -f lavfi -i "$B" -c:a pcm_s16le reference.wav
ffmpeg -f lavfi -i "$A" -c:a pcm_s16le first.wav
ffmpeg -f lavfi -i "$B" -t 9 -c:a pcm_s16le second.wav
ffmpeg -i first.wav -i second.wav -filter_complex "[0][1]concat=n=2:v=0:a=1[a]" -map "[a]" tunes.wav
ffmpeg -f lavfi -i "testsrc2=size=160x90:rate=12:duration=20" -i tunes.wav -c:v libx264 -preset medium -g 24 -b:v 30k -pix_fmt yuv420p -bsf:v filter_units=remove_types=6 -c:a aac -b:a 96k -ac 2 $BE songclip_melody.mkv
ffmpeg -i reference.wav -c:a aac -b:a 64k -ac 1 $BE songclip_melody_reference.m4a
```

`songclip_other_reference.m4a` is a third tune, for a catalogue that knows no song in the clip:

```sh
ffmpeg -f lavfi -i "aevalsrc=exprs='0.4*sin(2*PI*t*(330+97*mod(floor(t*3)*5\,13)))':s=44100:d=20" -c:a aac -b:a 64k -ac 1 $BE songclip_other_reference.m4a
```

The files were made with the Homebrew build of FFmpeg 9.0.2, which includes libx264.
