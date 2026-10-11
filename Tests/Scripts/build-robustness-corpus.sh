#!/bin/bash
# Tests/Scripts/build-robustness-corpus.sh — Wave-5 robustness corpus (plan §48).
# Generates the generable sample set + records expected metadata for
# automated verification. DTS samples can't be generated with ffmpeg; the
# repo's video.mkv covers H.264+DTS and the Download folder has HEVC rips —
# record them separately. HEVC+AAC MP4 is generated (libx265).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS="${1:-${SCRIPT_DIR}/../Corpus}"
mkdir -p "$CORPUS"
cd "$CORPUS"

gen() {  # gen <name> <ffmpeg args...>
  local name=$1; shift
  echo "== generating $name"
  ffmpeg -y -hide_banner -loglevel error "$@" "$name"
}

# 1. H.264 + AAC in Matroska (AAC decodes through AudioToolbox)
gen h264-aac.mkv -f lavfi -i testsrc2=duration=10:size=640x360:rate=30 \
  -f lavfi -i anullsrc=r=48000:cl=stereo -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest

# 2. H.264 video-only (silent)
gen h264-videoonly.mkv -f lavfi -i testsrc2=duration=10:size=640x360:rate=30 \
  -c:v libx264 -pix_fmt yuv420p -an

# 3. H.264 + SRT subtitles
printf '1\n00:00:00,500 --> 00:00:02,500\nCorpus sub one\n\n2\n00:00:03,000 --> 00:00:05,000\nCorpus sub two\n' > "$CORPUS/_t.srt"
gen h264-srt.mkv -f lavfi -i testsrc2=duration=10:size=640x360:rate=30 \
  -i "$CORPUS/_t.srt" -c:v libx264 -pix_fmt yuv420p -c:s srt -an

# 4. H.264 + ASS subtitles
printf '[Script Info]\nScriptType: v4.00+\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:00,500,0:00:02,500,Default,,0,0,0,,Corpus ASS line\n' > "$CORPUS/_t.ass"
gen h264-ass.mkv -f lavfi -i testsrc2=duration=10:size=640x360:rate=30 \
  -i "$CORPUS/_t.ass" -c:v libx264 -pix_fmt yuv420p -c:s ass -an

# 5. H.264 + multiple audio tracks (2x AAC)
gen h264-multiaudio.mkv -f lavfi -i testsrc2=duration=10:size=640x360:rate=30 \
  -f lavfi -i anullsrc=r=48000:cl=stereo -f lavfi -i anullsrc=r=44100:cl=mono \
  -map 0:v -map 1:a -map 2:a -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest

# 6. H.264 + chapters (via ffmetadata file)
cat > "$CORPUS/_t.meta" <<'EOF'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=10000
title=Chapter One
[CHAPTER]
TIMEBASE=1/1000
START=10000
END=20000
title=Chapter Two
[CHAPTER]
TIMEBASE=1/1000
START=20000
END=30000
title=Chapter Three
EOF
gen h264-chapters.mkv -f lavfi -i testsrc2=duration=30:size=640x360:rate=30 \
  -f ffmetadata -i "$CORPUS/_t.meta" -map 0:v -map_metadata 1 \
  -c:v libx264 -pix_fmt yuv420p -an

# 7. H.264 + font attachment
gen h264-attachments.mkv -f lavfi -i testsrc2=duration=10:size=640x360:rate=30 \
  -c:v libx264 -pix_fmt yuv420p -an \
  -attach /System/Library/Fonts/Helvetica.ttc -metadata:s:t:0 mimetype=application/x-truetype-font \
  -metadata:s:t:0 filename=helvetica.ttc

# 8. No-duration metadata: streamed-style (no duration in header) — mux with
#    a non-seekable output to omit duration, then remux. (Raw command: the
#    output is a pipe, not a gen()-appended filename.)
echo "== generating h264-noduration.mkv"
ffmpeg -y -hide_banner -loglevel error -f lavfi -i testsrc2=duration=10:size=640x360:rate=30 \
  -c:v libx264 -pix_fmt yuv420p -an -f matroska pipe:1 2>/dev/null | \
  ffmpeg -y -hide_banner -loglevel error -i pipe:0 -c copy -f matroska h264-noduration.mkv

# 9. Truncated: cut the last 20 % of a valid file.
gen h264-videoonly-tmp.mkv -f lavfi -i testsrc2=duration=10:size=640x360:rate=30 \
  -c:v libx264 -pix_fmt yuv420p -an
SIZE=$(stat -f%z h264-videoonly-tmp.mkv)
head -c $((SIZE * 8 / 10)) h264-videoonly-tmp.mkv > h264-truncated.mkv
rm -f h264-videoonly-tmp.mkv

# 10. Corrupt: flip bytes in the middle.
cp h264-videoonly.mkv h264-corrupt.mkv
CSIZE=$(stat -f%z h264-corrupt.mkv)
printf '\xde\xad\xbe\xef' | dd of=h264-corrupt.mkv bs=1 seek=$((CSIZE * 4 / 10)) conv=notrunc 2>/dev/null

# 11. Long file (2 min at small res).
gen h264-long.mkv -f lavfi -i testsrc2=duration=120:size=320x180:rate=30 \
  -c:v libx264 -pix_fmt yuv420p -an

# 12-14. Playable AC3 samples for Tests/SomePlayerTests/PlaybackIntegrationTests.
# Mono AC3 FIRST (used to crash), then stereo AC3, + SRT + ASS subtitles.
gen h264-ac3-mono-stereo-subs.mkv -f lavfi -i testsrc2=duration=8:size=640x360:rate=24 \
  -f lavfi -i "sine=frequency=440:duration=8" -f lavfi -i "sine=frequency=660:duration=8" \
  -i "$CORPUS/_t.srt" -i "$CORPUS/_t.ass" -map 0 -map 1 -map 2 -map 3 -map 4 \
  -c:v libx264 -pix_fmt yuv420p -g 48 -c:a ac3 -ac:a:0 1 -ac:a:1 2 -c:s:0 srt -c:s:1 ass
# Two decodable tracks, AAC first and 5.1 AC3 second.
gen h264-aac-then-ac3-51.mkv -f lavfi -i testsrc2=duration=8:size=640x360:rate=24 \
  -f lavfi -i "sine=frequency=440:duration=8" -f lavfi -i "sine=frequency=550:duration=8" \
  -map 0 -map 1 -map 2 -c:v libx264 -pix_fmt yuv420p -c:a:0 aac -c:a:1 ac3 -ac:a:1 6
# Short stereo AC3 file: plays to the end quickly.
gen h264-ac3-short.mkv -f lavfi -i testsrc2=duration=4:size=640x360:rate=24 \
  -f lavfi -i "sine=duration=4" -c:v libx264 -pix_fmt yuv420p -c:a ac3 -ac 2

# 15-16. Undecodable audio (FLAC): first-track gate and graceful reject.
gen h264-flac-then-ac3-51.mkv -f lavfi -i testsrc2=duration=8:size=640x360:rate=24 \
  -f lavfi -i "sine=frequency=440:duration=8" -f lavfi -i "sine=frequency=550:duration=8" \
  -map 0 -map 1 -map 2 -c:v libx264 -pix_fmt yuv420p -c:a:0 flac -c:a:1 ac3 -ac:a:1 6
gen h264-flac.mkv -f lavfi -i testsrc2=duration=4:size=640x360:rate=24 \
  -f lavfi -i "sine=duration=4" -c:v libx264 -pix_fmt yuv420p -c:a flac

# 17-20. MP4 (mov demuxer; AAC via AudioToolbox). The audio is a 440 Hz tone
# so playback tests can tell decoded audio from silence. libx264's default
# B-frames give the video an edit list and negative DTS; AAC's encoder
# priming arrives as an edit list (skip-samples on the first packet).
MP4_V=(-f lavfi -i testsrc2=duration=10:size=640x360:rate=30)
MP4_A=(-f lavfi -i sine=frequency=440:duration=10:sample_rate=48000)
gen h264-aac.mp4 "${MP4_V[@]}" "${MP4_A[@]}" -c:v libx264 -pix_fmt yuv420p \
  -c:a aac -ac 2 -movflags +faststart
gen hevc-aac.mp4 "${MP4_V[@]}" "${MP4_A[@]}" -c:v libx265 -x265-params log-level=error \
  -pix_fmt yuv420p -tag:v hvc1 -c:a aac -ac 2 -movflags +faststart
# 5.1 AAC: AAC's channel order is centre-first; the decoder reorders it.
gen h264-aac-51.mp4 "${MP4_V[@]}" "${MP4_A[@]}" -c:v libx264 -pix_fmt yuv420p \
  -c:a aac -ac 6 -movflags +faststart
# HE-AAC v2 (Apple's encoder; profile 28 = aac_he_v2): the header describes a
# 24 kHz mono core, the decoder outputs 48 kHz stereo.
gen h264-heaacv2.mp4 "${MP4_V[@]}" "${MP4_A[@]}" -c:v libx264 -pix_fmt yuv420p \
  -c:a aac_at -profile:a 28 -ac 2 -movflags +faststart

rm -f "$CORPUS/_t.srt" "$CORPUS/_t.ass" "$CORPUS/_t.meta"

echo
echo "== corpus complete: $(ls *.mkv *.mp4 | wc -l | tr -d ' ') files =="
ls -la *.mkv *.mp4 | awk '{print $5, $9}'

# Manifest: regenerate the expected-metadata table (plan section 48) so it
# always matches the generated set.
{
  echo "# Robustness Corpus — expected metadata (plan section 48)"
  echo
  echo "Generated by Tests/Scripts/build-robustness-corpus.sh. Verified via"
  echo "Tests/NativePoC/CorpusCheck/corpus-check.swift against the ThirdParty"
  echo "minimal build."
  echo
  echo "## Files"
  echo
  for f in *.mkv *.mp4; do
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | head -1)
    tracks=$(ffprobe -v error -show_entries stream=codec_type,codec_name,channels -of csv=p=0 "$f" 2>/dev/null \
      | paste -sd ' ' -)
    chaps=$(ffprobe -v error -show_entries format=format_name -of csv=p=0 "$f" >/dev/null 2>&1; \
      ffprobe -v error -show_chapters -of csv=p=0 "$f" 2>/dev/null | wc -l | tr -d ' ')
    echo "- $f  ${dur}s  [$tracks]  chapters=$chaps"
  done
  echo
  echo "## Real-file references (DTS can't be encoded by ffmpeg)"
  echo
  echo "- video.mkv (repo): 7903.478 s, h264 1920x816 + 2x dts 6ch 48kHz +"
  echo "  4x subrip, 32 chapters — the primary acceptance file."
  echo "- ~/Downloads/*.mkv rips: HEVC/AAC/AC3 mixes — Phase 7 material."
  echo
  echo "## Notes"
  echo
  echo "- AAC (MKV and MP4) decodes through AudioToolbox, not FFmpeg."
  echo "- h264-flac / h264-flac-then-ac3-51: FLAC is not decodable — expect"
  echo "  graceful rejection / the AC3 track picked, not a crash."
  echo "- truncated/corrupt: open + enumerate, decode fails mid-stream with"
  echo "  libavformat \"File ended prematurely\" — expected robustness."
} > "$CORPUS/MANIFEST.md"
echo "manifest written: $CORPUS/MANIFEST.md"
