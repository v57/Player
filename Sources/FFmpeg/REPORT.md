# FFmpeg minimal build report — Player

- Generated: 2026-10-11 16:23:10 +0300 by `Tests/Scripts/build-ffmpeg-macos.sh` on `mac.local`
- Host: macOS 27.0.1 (build 26A434), `arm64`
- Pinned revision: `n7.1.5`
- Commit: `3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587`
- Repository: https://github.com/FFmpeg/FFmpeg.git
- Pin verified: `git rev-parse HEAD` == 3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587

## Configure
```
/Users/v57/Developer/v57/Player/.claude/worktrees/charming-tharp-e907c8/build/ffmpeg/src/configure --disable-everything --disable-programs --disable-doc --disable-network --disable-autodetect --disable-static --enable-shared --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample --enable-avcodec --enable-avformat --enable-avutil --enable-demuxer=matroska --enable-demuxer=mov --enable-decoder=dca --enable-decoder=ac3 --enable-decoder=eac3 --enable-parser=ac3 --enable-protocol=file --arch=arm64 --extra-cflags=-mmacosx-version-min=12.0 --extra-ldflags=-mmacosx-version-min=12.0 --prefix=/Users/v57/Developer/v57/Player/.claude/worktrees/charming-tharp-e907c8/Sources/FFmpeg 
```
LGPL only (no `--enable-gpl`); shared only (`--disable-static`); arm64;
no external deps (`--disable-autodetect`); no Homebrew dependency.

## Component report (from `config_components.h`)
- Demuxers: MATROSKA_DEMUXER MOV_DEMUXER 
- Decoders: AC3_DECODER DCA_DECODER EAC3_DECODER 
- Parsers: AC3_PARSER 
- Protocols: FILE_PROTOCOL 
- Everything else disabled via `--disable-everything` (no filters, bsfs, hwaccels, muxers, encoders, other demuxers/protocols).

## Libraries built
```
total 3520
drwxr-xr-x@ 12 v57  staff     384 Oct 11 16:22 .
drwxr-xr-x@  9 v57  staff     288 Oct 11 16:23 ..
-rwxr-xr-x@  1 v57  staff  639960 Oct 11 16:22 libavcodec.61.19.101.dylib
lrwxr-xr-x@  1 v57  staff      26 Oct 11 16:22 libavcodec.61.dylib -> libavcodec.61.19.101.dylib
lrwxr-xr-x@  1 v57  staff      26 Oct 11 16:22 libavcodec.dylib -> libavcodec.61.19.101.dylib
-rwxr-xr-x@  1 v57  staff  452968 Oct 11 16:22 libavformat.61.7.103.dylib
lrwxr-xr-x@  1 v57  staff      26 Oct 11 16:22 libavformat.61.dylib -> libavformat.61.7.103.dylib
lrwxr-xr-x@  1 v57  staff      26 Oct 11 16:22 libavformat.dylib -> libavformat.61.7.103.dylib
-rwxr-xr-x@  1 v57  staff  700968 Oct 11 16:22 libavutil.59.39.100.dylib
lrwxr-xr-x@  1 v57  staff      25 Oct 11 16:22 libavutil.59.dylib -> libavutil.59.39.100.dylib
lrwxr-xr-x@  1 v57  staff      25 Oct 11 16:22 libavutil.dylib -> libavutil.59.39.100.dylib
drwxr-xr-x@  5 v57  staff     160 Oct 11 16:22 pkgconfig
```

## Architecture
- `libavcodec.61.19.101.dylib`: arm64, minimum macOS 12.0
- `libavformat.61.7.103.dylib`: arm64, minimum macOS 12.0
- `libavutil.59.39.100.dylib`: arm64, minimum macOS 12.0

## Size report (`du -h`)
```
628K	/Users/v57/Developer/v57/Player/.claude/worktrees/charming-tharp-e907c8/Sources/FFmpeg/lib/libavcodec.61.19.101.dylib
444K	/Users/v57/Developer/v57/Player/.claude/worktrees/charming-tharp-e907c8/Sources/FFmpeg/lib/libavformat.61.7.103.dylib
688K	/Users/v57/Developer/v57/Player/.claude/worktrees/charming-tharp-e907c8/Sources/FFmpeg/lib/libavutil.59.39.100.dylib
1.7M	/Users/v57/Developer/v57/Player/.claude/worktrees/charming-tharp-e907c8/Sources/FFmpeg/lib
3.1M	/Users/v57/Developer/v57/Player/.claude/worktrees/charming-tharp-e907c8/Sources/FFmpeg
```

## Install names (@rpath)
```
/Users/v57/Developer/v57/Player/.claude/worktrees/charming-tharp-e907c8/Sources/FFmpeg/lib/libavcodec.61.19.101.dylib:
	@rpath/libavcodec.61.19.101.dylib (compatibility version 61.0.0, current version 61.19.101)
	@rpath/libavutil.59.dylib (compatibility version 59.0.0, current version 59.39.100)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1359.0.0)
	/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation (compatibility version 150.0.0, current version 5027.0.69)
	/System/Library/Frameworks/CoreVideo.framework/Versions/A/CoreVideo (compatibility version 1.2.0, current version 758.27.0)
	/System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia (compatibility version 1.0.0, current version 3350.77.5)
/Users/v57/Developer/v57/Player/.claude/worktrees/charming-tharp-e907c8/Sources/FFmpeg/lib/libavformat.61.7.103.dylib:
	@rpath/libavformat.61.7.103.dylib (compatibility version 61.0.0, current version 61.7.103)
	@rpath/libavcodec.61.dylib (compatibility version 61.0.0, current version 61.19.101)
	@rpath/libavutil.59.dylib (compatibility version 59.0.0, current version 59.39.100)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1359.0.0)
	/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation (compatibility version 150.0.0, current version 5027.0.69)
	/System/Library/Frameworks/CoreVideo.framework/Versions/A/CoreVideo (compatibility version 1.2.0, current version 758.27.0)
	/System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia (compatibility version 1.0.0, current version 3350.77.5)
/Users/v57/Developer/v57/Player/.claude/worktrees/charming-tharp-e907c8/Sources/FFmpeg/lib/libavutil.59.39.100.dylib:
	@rpath/libavutil.59.39.100.dylib (compatibility version 59.0.0, current version 59.39.100)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1359.0.0)
	/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation (compatibility version 150.0.0, current version 5027.0.69)
	/System/Library/Frameworks/CoreVideo.framework/Versions/A/CoreVideo (compatibility version 1.2.0, current version 758.27.0)
	/System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia (compatibility version 1.0.0, current version 3350.77.5)
```
App resolves them via `LD_RUNPATH_SEARCH_PATHS = @executable_path/../Frameworks`.

## Sanity check (shipped libs)
### ffprobe — stream codec names of the corpus files (demux proof)
```
h264-ac3-short.mkv:
h264
ac3
h264-aac.mp4:
h264
aac
```
### C demux+decode test (matroska + mov demux, ac3 decode proof)
```
demuxer: matroska,webm, streams: 2
  stream 0: video h264
  stream 1: audio ac3
ac3 decoded: 1536 samples, 2 ch, 44100 Hz, fmt fltp
PASS: Tests/Corpus/h264-ac3-short.mkv demux + ac3 decode against shipped libs
demuxer: mov,mp4,m4a,3gp,3g2,mj2, streams: 2
  stream 0: video h264
  stream 1: audio aac
PASS: Tests/Corpus/h264-aac.mp4 demux (no FFmpeg-decoded audio stream)
```

## License
- LGPL v2.1+ only; NO GPL components (`--enable-gpl` never passed).
- `LICENSE`, `COPYING.LGPLv2.1`, `source-version.txt`, `README.md` shipped alongside.
