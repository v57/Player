#!/usr/bin/env bash
#=============================================================================
# build-ffmpeg-macos.sh
#
# Reproducible minimal LGPL FFmpeg build for the Player macOS app (arm64).
#
#   Pinned:  FFmpeg n7.1.5 @ 3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587
#   License: LGPL v2.1+ only — NO --enable-gpl (no GPL components).
#   Output:  ThirdParty/FFmpeg/{include,lib} + LICENSE, COPYING.LGPLv2.1,
#            source-version.txt, README.md, REPORT.md
#   Deps:    git, make, clang, strip, install_name_tool, otool (Xcode CLT).
#            NO Homebrew dependency: FFmpeg source is cloned from upstream.
#
# The three dylibs get @rpath/ install names so the app's
# LD_RUNPATH_SEARCH_PATHS (@executable_path/../Frameworks) resolves them.
#
# Usage: Tests/Scripts/build-ffmpeg-macos.sh [--clean]
#   --clean  wipe the scratch/build dirs first (full rebuild)
#=============================================================================
set -euo pipefail

#---- pinned revision --------------------------------------------------------
FFMPEG_TAG="n7.1.5"
FFMPEG_COMMIT="3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587"   # git rev-parse n7.1.5^{}
FFMPEG_REPO="https://github.com/FFmpeg/FFmpeg.git"

#---- paths ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PREFIX="${REPO_ROOT}/ThirdParty/FFmpeg"
SCRATCH="${REPO_ROOT}/build/ffmpeg"
SRC_DIR="${SCRATCH}/src"
LIB_BUILD_DIR="${SCRATCH}/build-libs"
PROBE_BUILD_DIR="${SCRATCH}/build-probe"
LOG_DIR="${SCRATCH}/logs"
BUILD_LOG="${LOG_DIR}/build.log"
CONFIGURE_LOG="${LOG_DIR}/configure.log"
JOBS="$(sysctl -n hw.ncpu)"

CLEAN=0
if [[ "${1:-}" == "--clean" ]]; then CLEAN=1; fi

mkdir -p "${SCRATCH}" "${LOG_DIR}"
: > "${BUILD_LOG}"
exec > >(tee -a "${BUILD_LOG}") 2>&1

echo "==> build-ffmpeg-macos.sh"
echo "    repo root : ${REPO_ROOT}"
echo "    prefix    : ${PREFIX}"
echo "    pinned    : ${FFMPEG_TAG} @ ${FFMPEG_COMMIT}"
echo "    jobs      : ${JOBS}"
echo "    scratch   : ${SCRATCH}"

if [[ "${CLEAN}" == "1" ]]; then
  echo "==> --clean: wiping scratch dir"
  rm -rf "${SCRATCH}"
  mkdir -p "${SCRATCH}" "${LOG_DIR}"
  : > "${BUILD_LOG}"
fi

#---- stage 1: obtain pinned FFmpeg source ----------------------------------
echo "==> stage 1: obtain pinned FFmpeg source (${FFMPEG_TAG})"
if [[ ! -d "${SRC_DIR}/.git" ]]; then
  git clone --quiet --depth 1 --branch "${FFMPEG_TAG}" "${FFMPEG_REPO}" "${SRC_DIR}"
fi
(
  cd "${SRC_DIR}"
  git fetch --quiet --depth 1 origin "refs/tags/${FFMPEG_TAG}"
  git checkout --quiet --detach "${FFMPEG_TAG}"
  actual="$(git rev-parse HEAD)"
  if [[ "${actual}" != "${FFMPEG_COMMIT}" ]]; then
    echo "ERROR: ${FFMPEG_TAG} resolves to ${actual}, expected ${FFMPEG_COMMIT} (pin mismatch)" >&2
    exit 1
  fi
  echo "    verified: ${FFMPEG_TAG} = ${actual}"
)

#---- configure flags (auditable; --disable-everything first, then re-enable)-
# LGPL only (no --enable-gpl), shared only (--disable-static), arm64 only.
# No h264 parser by design: AVCC extradata goes straight to VideoToolbox.
# --enable-parser=dca added only if configure complains (locked rule).
CONFIGURE_BASE=(
  --disable-everything
  --disable-programs
  --disable-doc
  --disable-network
  --disable-autodetect
  --disable-static
  --enable-shared
  --disable-avdevice
  --disable-avfilter
  --disable-swscale
  --disable-swresample
  --enable-avcodec
  --enable-avformat
  --enable-avutil
  --enable-demuxer=matroska
  --enable-decoder=dca
  --enable-decoder=ac3
  --enable-decoder=eac3
  --enable-parser=ac3
  --enable-protocol=file
  --arch=arm64
  --prefix="${PREFIX}"
)

run_configure() {
  local label="$1"; shift
  echo "---- configure (${label})"
  echo "${SRC_DIR}/configure ${CONFIGURE_BASE[*]} $*"
  if ! "${SRC_DIR}/configure" "${CONFIGURE_BASE[@]}" "$@" 2>&1 | tee -a "${CONFIGURE_LOG}"; then
    echo "configure (${label}) FAILED — tail of config.log:" >&2
    tail -n 40 config.log >&2
    return 1
  fi
}

#---- stage 2: configure (libs build, out-of-tree) ---------------------------
echo "==> stage 2: configure (libs build)"
rm -rf "${LIB_BUILD_DIR}"
mkdir -p "${LIB_BUILD_DIR}"
cd "${LIB_BUILD_DIR}"

PARSER_EXTRA=""
if ! run_configure "libs"; then
  echo "==> retrying with --enable-parser=dca"
  PARSER_EXTRA="--enable-parser=dca"
  if ! run_configure "libs+parser=dca" "${PARSER_EXTRA}"; then
    exit 1
  fi
fi

#---- stage 3: build ---------------------------------------------------------
echo "==> stage 3: build (make -j${JOBS})"
make -j"${JOBS}"

#---- stage 4: install -------------------------------------------------------
echo "==> stage 4: install to ${PREFIX}"
rm -rf "${PREFIX}"
make install

#---- stage 5: license + version + readme ------------------------------------
echo "==> stage 5: license + version + readme"
cp "${SRC_DIR}/LICENSE.md" "${PREFIX}/LICENSE"
cp "${SRC_DIR}/COPYING.LGPLv2.1" "${PREFIX}/COPYING.LGPLv2.1"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M:%S %z')"
cat > "${PREFIX}/source-version.txt" <<EOF
FFmpeg pinned revision : ${FFMPEG_TAG}
Commit                 : ${FFMPEG_COMMIT}
Repository             : ${FFMPEG_REPO}
Built by               : Tests/Scripts/build-ffmpeg-macos.sh
Build date             : ${BUILD_DATE}
EOF

cat > "${PREFIX}/README.md" <<EOF
# FFmpeg (minimal, LGPL) — ThirdParty/FFmpeg

Minimal shared FFmpeg build for the Player macOS app (arm64): Matroska
demuxing + DTS (dca), Dolby Digital (ac3) and E-AC3 (eac3) decoding.
Pinned to FFmpeg ${FFMPEG_TAG}
(${FFMPEG_COMMIT}). Reproduced by \`Tests/Scripts/build-ffmpeg-macos.sh\` — no
Homebrew dependency (the script clones the pinned tag itself).

## Layout
- \`include/\` — libavformat / libavcodec / libavutil headers
- \`lib/\`     — libavformat.61.dylib, libavcodec.61.dylib, libavutil.59.dylib
  (+ unversioned symlinks, pkgconfig)
- \`LICENSE\`, \`COPYING.LGPLv2.1\` — LGPL v2.1+ (no GPL components)
- \`source-version.txt\` — pinned tag + commit
- \`REPORT.md\` — configure line, component + size report, install names,
  sanity-check results

## Rebuild
    Tests/Scripts/build-ffmpeg-macos.sh [--clean]

## Enabled components
\`demuxer=matroska\`, \`decoder=dca\`, \`decoder=ac3\`, \`decoder=eac3\`,
\`parser=ac3\`, \`protocol=file\`; everything else
disabled (\`--disable-everything\`). NO \`--enable-gpl\` → LGPL v2.1+ only.
No h264 parser by design: H.264 (AVCC extradata) goes straight to
VideoToolbox (\`CMVideoFormatDescriptionCreateFromH264ParameterSets\`).

## Runtime linkage
The dylibs carry \`@rpath/\` install names (e.g.
\`@rpath/libavformat.61.dylib\`). The app's
\`LD_RUNPATH_SEARCH_PATHS = @executable_path/../Frameworks\` resolves them:
copy the three versioned dylibs into \`<App>.app/Contents/Frameworks\`.

## LGPL obligations (relink story)
- LGPL v2.1+; no GPL components (no \`--enable-gpl\` in the configure line).
- The app links dynamically against the shared dylibs; a user may relink
  against their own build of the same source revision — the pinned tag +
  commit are recorded in \`source-version.txt\`, and this script reproduces
  the build.
- License texts shipped alongside.
EOF

#---- stage 6: strip ---------------------------------------------------------
echo "==> stage 6: strip -x dylibs"
for f in "${PREFIX}"/lib/libav*.dylib; do
  [[ -f "${f}" && ! -L "${f}" ]] || continue
  strip -x "${f}"
  echo "    stripped ${f##*/}"
done

#---- stage 7: @rpath install names on the three dylibs -----------------------
echo "==> stage 7: @rpath install names"
AV_LIBS=()
for base in libavcodec libavformat libavutil; do
  for f in "${PREFIX}"/lib/${base}.*.dylib; do
    [[ -f "${f}" && ! -L "${f}" ]] && AV_LIBS+=("${f}")
  done
done

for f in "${AV_LIBS[@]}"; do
  install_name_tool -id "@rpath/$(basename "${f}")" "${f}"
  echo "    id: ${f##*/} -> @rpath/$(basename "${f}")"
done

for f in "${AV_LIBS[@]}"; do
  while IFS= read -r dep; do
    dep="${dep#"${dep%%[![:space:]]*}"}"   # strip leading whitespace
    dep="${dep%% (*}"                       # drop " (compatibility ...)"
    if [[ "${dep}" == "${PREFIX}/lib/"* ]]; then
      install_name_tool -change "${dep}" "@rpath/$(basename "${dep}")" "${f}"
      echo "    ${f##*/}: ${dep} -> @rpath/$(basename "${dep}")"
    fi
  done < <(otool -L "${f}" | tail -n +2)
done

#---- stage 8: one-off ffprobe against the SHIPPED libs (not installed) -------
# Same component set, programs on for ffprobe only. Built with the SAME
# --prefix so its recorded lib paths point at the shipped dylibs; an added
# LC_RPATH makes the shipped libs' @rpath deps resolve. Proves demux of the
# target file with the exact dylibs the app will ship.
echo "==> stage 8: one-off ffprobe against shipped libs (not installed)"
rm -rf "${PROBE_BUILD_DIR}"
mkdir -p "${PROBE_BUILD_DIR}"
cd "${PROBE_BUILD_DIR}"
PROBE_FLAGS=()
for fl in "${CONFIGURE_BASE[@]}"; do
  [[ "${fl}" == "--disable-programs" ]] && continue
  PROBE_FLAGS+=("${fl}")
done
PROBE_FLAGS+=(--enable-ffprobe --disable-ffmpeg --disable-ffplay)
PROBE_FLAGS+=(--extra-ldflags=-Wl,-headerpad_max_install_names)
echo "${SRC_DIR}/configure ${PROBE_FLAGS[*]}"
"${SRC_DIR}/configure" "${PROBE_FLAGS[@]}" 2>&1 | tee -a "${CONFIGURE_LOG}"
make -j"${JOBS}" ffprobe
# Prefer LC_RPATH (mirrors the app story); DYLD_LIBRARY_PATH below is the
# fallback if the binary lacks headerpad for a new load command.
install_name_tool -add_rpath "${PREFIX}/lib" "${PROBE_BUILD_DIR}/ffprobe" \
  || echo "    note: -add_rpath skipped (headerpad); DYLD_LIBRARY_PATH will be used"
echo "    ffprobe: ${PROBE_BUILD_DIR}/ffprobe (rpath=${PREFIX}/lib)"

#---- stage 9: sanity checks against the SHIPPED libs --------------------------
echo "==> stage 9: sanity checks"
FFPROBE="${PROBE_BUILD_DIR}/ffprobe"
# DYLD_LIBRARY_PATH makes dyld prefer the SHIPPED libs (searched before the
# recorded install name and before @rpath) — the task's own sanity form.
FFPROBE_RUN=(env DYLD_LIBRARY_PATH="${PREFIX}/lib" "${FFPROBE}")
echo "---- ffprobe — stream codec names of video.mkv (demux proof, shipped libs)"
"${FFPROBE_RUN[@]}" -v error -show_entries stream=codec_name -of csv=p=0 "${REPO_ROOT}/video.mkv" \
  | tee "${LOG_DIR}/ffprobe-streams.txt"

cat > "${SCRATCH}/sanity_demux_decode.c" <<'C_EOF'
/*
 * sanity_demux_decode.c — prove the minimal FFmpeg build (shipped dylibs)
 * demuxes Matroska and decodes DTS from video.mkv. Linked against
 * ThirdParty/FFmpeg/lib with -rpath, mirroring the app's
 * @executable_path/../Frameworks run-path story.
 */
#include <stdio.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <file.mkv>\n", argv[0]); return 2; }

    AVFormatContext *fmt = NULL;
    int ret = avformat_open_input(&fmt, argv[1], NULL, NULL);
    if (ret < 0) { fprintf(stderr, "FAIL avformat_open_input: %d\n", ret); return 1; }
    ret = avformat_find_stream_info(fmt, NULL);
    if (ret < 0) { fprintf(stderr, "FAIL avformat_find_stream_info: %d\n", ret); return 1; }

    printf("demuxer: %s, streams: %d\n", fmt->iformat->name, fmt->nb_streams);
    int dts_index = -1;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream *s = fmt->streams[i];
        const char *type = av_get_media_type_string(s->codecpar->codec_type);
        printf("  stream %u: %s %s\n", i, type ? type : "?",
               avcodec_get_name(s->codecpar->codec_id));
        if (s->codecpar->codec_id == AV_CODEC_ID_DTS && dts_index < 0)
            dts_index = (int)i;
    }
    if (dts_index < 0) { fprintf(stderr, "FAIL: no DTS stream found\n"); return 1; }

    AVCodecParameters *par = fmt->streams[dts_index]->codecpar;
    const AVCodec *dec = avcodec_find_decoder(par->codec_id);
    if (!dec) { fprintf(stderr, "FAIL: dca decoder not found\n"); return 1; }
    AVCodecContext *ctx = avcodec_alloc_context3(dec);
    if (avcodec_parameters_to_context(ctx, par) < 0) { fprintf(stderr, "FAIL: params->ctx\n"); return 1; }
    if (avcodec_open2(ctx, dec, NULL) < 0) { fprintf(stderr, "FAIL: avcodec_open2 (dca)\n"); return 1; }

    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int decoded = 0;
    while (av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index == dts_index) {
            if (avcodec_send_packet(ctx, pkt) >= 0) {
                while (avcodec_receive_frame(ctx, frame) >= 0) {
                    printf("DTS decoded: %d samples, %d ch, %d Hz, fmt %s\n",
                           frame->nb_samples,
                           frame->ch_layout.nb_channels,
                           frame->sample_rate,
                           av_get_sample_fmt_name(frame->format));
                    decoded = 1;
                    break;
                }
            }
            if (decoded) break;
        }
        av_packet_unref(pkt);
    }
    if (!decoded) { fprintf(stderr, "FAIL: no DTS frame decoded\n"); return 1; }

    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    printf("PASS: matroska demux + dca decode against shipped libs\n");
    return 0;
}
C_EOF

echo "---- C demux+decode test (shipped libs, @rpath resolution)"
clang -O2 -I "${PREFIX}/include" "${SCRATCH}/sanity_demux_decode.c" \
  -L "${PREFIX}/lib" -lavformat -lavcodec -lavutil \
  -Xlinker -rpath -Xlinker "${PREFIX}/lib" \
  -o "${SCRATCH}/sanity_demux_decode"
"${SCRATCH}/sanity_demux_decode" "${REPO_ROOT}/video.mkv" | tee "${LOG_DIR}/ctest.txt"

#---- stage 10: REPORT.md ------------------------------------------------------
echo "==> stage 10: REPORT.md"
CFG="${LIB_BUILD_DIR}/config_components.h"
demuxers="$(grep -E '^#define CONFIG_.*_DEMUXER 1$' "${CFG}" | sed 's/^#define CONFIG_//; s/ 1$//' | tr '\n' ' ' || true)"
decoders="$(grep -E '^#define CONFIG_.*_DECODER 1$' "${CFG}" | sed 's/^#define CONFIG_//; s/ 1$//' | tr '\n' ' ' || true)"
parsers="$(grep -E '^#define CONFIG_.*_PARSER 1$' "${CFG}" | sed 's/^#define CONFIG_//; s/ 1$//' | tr '\n' ' ' || true)"
protocols="$(grep -E '^#define CONFIG_.*_PROTOCOL 1$' "${CFG}" | sed 's/^#define CONFIG_//; s/ 1$//' | tr '\n' ' ' || true)"
[[ -z "${demuxers}" ]] && demuxers="(none)"
[[ -z "${decoders}" ]] && decoders="(none)"
[[ -z "${parsers}" ]] && parsers="(none)"
[[ -z "${protocols}" ]] && protocols="(none)"

{
  echo "# FFmpeg minimal build report — Player"
  echo
  echo "- Generated: $(date '+%Y-%m-%d %H:%M:%S %z') by \`Tests/Scripts/build-ffmpeg-macos.sh\` on \`$(hostname)\`"
  echo "- Host: macOS $(sw_vers -productVersion) (build $(sw_vers -buildVersion)), \`$(uname -m)\`"
  echo "- Pinned revision: \`${FFMPEG_TAG}\`"
  echo "- Commit: \`${FFMPEG_COMMIT}\`"
  echo "- Repository: ${FFMPEG_REPO}"
  echo "- Pin verified: \`git rev-parse HEAD\` == ${FFMPEG_COMMIT}"
  echo
  echo "## Configure"
  echo '```'
  echo "${SRC_DIR}/configure ${CONFIGURE_BASE[*]} ${PARSER_EXTRA}"
  echo '```'
  echo "LGPL only (no \`--enable-gpl\`); shared only (\`--disable-static\`); arm64;"
  echo "no external deps (\`--disable-autodetect\`); no Homebrew dependency."
  echo
  echo "## Component report (from \`config_components.h\`)"
  echo "- Demuxers: ${demuxers}"
  echo "- Decoders: ${decoders}"
  echo "- Parsers: ${parsers}"
  echo "- Protocols: ${protocols}"
  echo "- Everything else disabled via \`--disable-everything\` (no filters, bsfs, hwaccels, muxers, encoders, other demuxers/protocols)."
  echo
  echo "## Libraries built"
  echo '```'
  ls -la "${PREFIX}/lib"
  echo '```'
  echo
  echo "## Architecture"
  for f in "${AV_LIBS[@]}"; do
    echo "- \`$(basename "${f}")\`: $(lipo -archs "${f}")"
  done
  echo
  echo "## Size report (\`du -h\`)"
  echo '```'
  for f in "${AV_LIBS[@]}"; do du -h "${f}"; done
  du -sh "${PREFIX}/lib"
  du -sh "${PREFIX}"
  echo '```'
  echo
  echo "## Install names (@rpath)"
  echo '```'
  for f in "${AV_LIBS[@]}"; do otool -L "${f}"; done
  echo '```'
  echo "App resolves them via \`LD_RUNPATH_SEARCH_PATHS = @executable_path/../Frameworks\`."
  echo
  echo "## Sanity check (shipped libs)"
  echo "### ffprobe — stream codec names of \`video.mkv\` (demux proof)"
  echo '```'
  cat "${LOG_DIR}/ffprobe-streams.txt"
  echo '```'
  echo "### C demux+decode test (matroska demux + dca decode proof)"
  echo '```'
  cat "${LOG_DIR}/ctest.txt"
  echo '```'
  echo
  echo "## License"
  echo "- LGPL v2.1+ only; NO GPL components (\`--enable-gpl\` never passed)."
  echo "- \`LICENSE\`, \`COPYING.LGPLv2.1\`, \`source-version.txt\`, \`README.md\` shipped alongside."
} > "${PREFIX}/REPORT.md"
echo "    wrote ${PREFIX}/REPORT.md"

#---- stage 11: verification ---------------------------------------------------
echo "==> stage 11: verification"
ok=1
for f in "${AV_LIBS[@]}"; do
  if ! otool -L "${f}" | grep -q '@rpath/'; then
    echo "ERROR: ${f} missing @rpath install names" >&2
    ok=0
  fi
done
"${FFPROBE_RUN[@]}" -version | head -1
[[ "${ok}" == "1" ]] || exit 1

echo
echo "==> DONE. Install: ${PREFIX}"
echo "==> Full log: ${BUILD_LOG}"
