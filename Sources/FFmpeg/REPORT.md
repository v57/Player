# FFmpeg minimal build report — Player

- Generated: 2026-08-18 10:57:16 +0700 by `Tests/Scripts/build-ffmpeg-macos.sh` on `mac.local`
- Host: macOS 27.0 (build 26A5406e), `arm64`
- Pinned revision: `n7.1.5`
- Commit: `3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587`
- Repository: https://github.com/FFmpeg/FFmpeg.git
- Pin verified: `git rev-parse HEAD` == 3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587

## Configure
```
/Users/v57/Projects/Player/build/ffmpeg/src/configure --disable-everything --disable-programs --disable-doc --disable-network --disable-autodetect --disable-static --enable-shared --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample --enable-avcodec --enable-avformat --enable-avutil --enable-demuxer=matroska --enable-decoder=dca --enable-decoder=ac3 --enable-decoder=eac3 --enable-parser=ac3 --enable-protocol=file --arch=arm64 --prefix=/Users/v57/Projects/Player/ThirdParty/FFmpeg 
```
LGPL only (no `--enable-gpl`); shared only (`--disable-static`); arm64;
no external deps (`--disable-autodetect`); no Homebrew dependency.

## Component report (from `config_components.h`)
- Demuxers: MATROSKA_DEMUXER 
- Decoders: AC3_DECODER DCA_DECODER EAC3_DECODER 
- Parsers: AC3_PARSER 
- Protocols: FILE_PROTOCOL 
- Everything else disabled via `--disable-everything` (no filters, bsfs, hwaccels, muxers, encoders, other demuxers/protocols).

## Libraries built
```
total 3216
drwxr-xr-x@ 12 v57  staff     384 Aug 18 10:56 .
drwxr-xr-x@ 10 v57  staff     320 Aug 18 10:57 ..
-rwxr-xr-x@  1 v57  staff  639880 Aug 18 10:56 libavcodec.61.19.101.dylib
lrwxr-xr-x@  1 v57  staff      26 Aug 18 10:56 libavcodec.61.dylib -> libavcodec.61.19.101.dylib
lrwxr-xr-x@  1 v57  staff      26 Aug 18 10:56 libavcodec.dylib -> libavcodec.61.19.101.dylib
-rwxr-xr-x@  1 v57  staff  298680 Aug 18 10:56 libavformat.61.7.103.dylib
lrwxr-xr-x@  1 v57  staff      26 Aug 18 10:56 libavformat.61.dylib -> libavformat.61.7.103.dylib
lrwxr-xr-x@  1 v57  staff      26 Aug 18 10:56 libavformat.dylib -> libavformat.61.7.103.dylib
-rwxr-xr-x@  1 v57  staff  700968 Aug 18 10:56 libavutil.59.39.100.dylib
lrwxr-xr-x@  1 v57  staff      25 Aug 18 10:56 libavutil.59.dylib -> libavutil.59.39.100.dylib
lrwxr-xr-x@  1 v57  staff      25 Aug 18 10:56 libavutil.dylib -> libavutil.59.39.100.dylib
drwxr-xr-x@  5 v57  staff     160 Aug 18 10:56 pkgconfig
```

## Architecture
- `libavcodec.61.19.101.dylib`: arm64
- `libavformat.61.7.103.dylib`: arm64
- `libavutil.59.39.100.dylib`: arm64

## Size report (`du -h`)
```
628K	/Users/v57/Projects/Player/ThirdParty/FFmpeg/lib/libavcodec.61.19.101.dylib
292K	/Users/v57/Projects/Player/ThirdParty/FFmpeg/lib/libavformat.61.7.103.dylib
688K	/Users/v57/Projects/Player/ThirdParty/FFmpeg/lib/libavutil.59.39.100.dylib
1.6M	/Users/v57/Projects/Player/ThirdParty/FFmpeg/lib
3.2M	/Users/v57/Projects/Player/ThirdParty/FFmpeg
```

## Install names (@rpath)
```
/Users/v57/Projects/Player/ThirdParty/FFmpeg/lib/libavcodec.61.19.101.dylib:
	@rpath/libavcodec.61.19.101.dylib (compatibility version 61.0.0, current version 61.19.101)
	@rpath/libavutil.59.dylib (compatibility version 59.0.0, current version 59.39.100)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1359.0.0)
	/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation (compatibility version 150.0.0, current version 5027.0.63)
	/System/Library/Frameworks/CoreVideo.framework/Versions/A/CoreVideo (compatibility version 1.2.0, current version 758.25.0)
	/System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia (compatibility version 1.0.0, current version 3350.71.2)
/Users/v57/Projects/Player/ThirdParty/FFmpeg/lib/libavformat.61.7.103.dylib:
	@rpath/libavformat.61.7.103.dylib (compatibility version 61.0.0, current version 61.7.103)
	@rpath/libavcodec.61.dylib (compatibility version 61.0.0, current version 61.19.101)
	@rpath/libavutil.59.dylib (compatibility version 59.0.0, current version 59.39.100)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1359.0.0)
	/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation (compatibility version 150.0.0, current version 5027.0.63)
	/System/Library/Frameworks/CoreVideo.framework/Versions/A/CoreVideo (compatibility version 1.2.0, current version 758.25.0)
	/System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia (compatibility version 1.0.0, current version 3350.71.2)
/Users/v57/Projects/Player/ThirdParty/FFmpeg/lib/libavutil.59.39.100.dylib:
	@rpath/libavutil.59.39.100.dylib (compatibility version 59.0.0, current version 59.39.100)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1359.0.0)
	/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation (compatibility version 150.0.0, current version 5027.0.63)
	/System/Library/Frameworks/CoreVideo.framework/Versions/A/CoreVideo (compatibility version 1.2.0, current version 758.25.0)
	/System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia (compatibility version 1.0.0, current version 3350.71.2)
```
App resolves them via `LD_RUNPATH_SEARCH_PATHS = @executable_path/../Frameworks`.

## Sanity check (shipped libs)
### ffprobe — stream codec names of `video.mkv` (demux proof)
```
h264
ac3
dts
dts
subrip
subrip
```
### C demux+decode test (matroska demux + dca decode proof)
```
demuxer: matroska,webm, streams: 6
  stream 0: video h264
  stream 1: audio ac3
  stream 2: audio dts
  stream 3: audio dts
  stream 4: subtitle subrip
  stream 5: subtitle subrip
DTS decoded: 512 samples, 6 ch, 48000 Hz, fmt fltp
PASS: matroska demux + dca decode against shipped libs
```

## License
- LGPL v2.1+ only; NO GPL components (`--enable-gpl` never passed).
- `LICENSE`, `COPYING.LGPLv2.1`, `source-version.txt`, `README.md` shipped alongside.
