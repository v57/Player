# FFmpeg (minimal, LGPL) — ThirdParty/FFmpeg

Minimal shared FFmpeg build for the Player macOS app (arm64): Matroska
demuxing + DTS (dca), Dolby Digital (ac3) and E-AC3 (eac3) decoding.
Pinned to FFmpeg n7.1.5
(3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587). Reproduced by `Tests/Scripts/build-ffmpeg-macos.sh` — no
Homebrew dependency (the script clones the pinned tag itself).

## Layout
- `include/` — libavformat / libavcodec / libavutil headers
- `lib/`     — libavformat.61.dylib, libavcodec.61.dylib, libavutil.59.dylib
  (+ unversioned symlinks, pkgconfig)
- `LICENSE`, `COPYING.LGPLv2.1` — LGPL v2.1+ (no GPL components)
- `source-version.txt` — pinned tag + commit
- `REPORT.md` — configure line, component + size report, install names,
  sanity-check results

## Rebuild
    Tests/Scripts/build-ffmpeg-macos.sh [--clean]

## Enabled components
`demuxer=matroska`, `decoder=dca`, `decoder=ac3`, `decoder=eac3`,
`parser=ac3`, `protocol=file`; everything else
disabled (`--disable-everything`). NO `--enable-gpl` → LGPL v2.1+ only.
No h264 parser by design: H.264 (AVCC extradata) goes straight to
VideoToolbox (`CMVideoFormatDescriptionCreateFromH264ParameterSets`).

## Runtime linkage
The dylibs carry `@rpath/` install names (e.g.
`@rpath/libavformat.61.dylib`). The app's
`LD_RUNPATH_SEARCH_PATHS = @executable_path/../Frameworks` resolves them:
copy the three versioned dylibs into `<App>.app/Contents/Frameworks`.

## LGPL obligations (relink story)
- LGPL v2.1+; no GPL components (no `--enable-gpl` in the configure line).
- The app links dynamically against the shared dylibs; a user may relink
  against their own build of the same source revision — the pinned tag +
  commit are recorded in `source-version.txt`, and this script reproduces
  the build.
- License texts shipped alongside.
