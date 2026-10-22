#!/bin/zsh
# Makes the video Player's screenshots (.dev/screenshots.json) play: a minute of slowly moving color with a quiet
# tone, generated with ffmpeg (brew install ffmpeg), so the pictures show no one's real media.
# Usage: Tools/screenshots/make-demo.sh [folder]   (default /tmp/PlayerDemo, as .dev/screenshots.json expects)
set -euo pipefail
demo=${1:-/tmp/PlayerDemo}
mkdir -p "$demo"
ffmpeg -loglevel error -y \
  -f lavfi -i "gradients=s=1920x1080:c0=0x1b2a6b:c1=0x0f8f7a:c2=0x6b2a8f:c3=0xe0702a:speed=0.008:duration=60:rate=30" \
  -f lavfi -i "sine=frequency=220:duration=60:sample_rate=48000,volume=0.05" \
  -c:v libx264 -pix_fmt yuv420p -crf 20 -c:a aac -b:a 96k -shortest \
  -metadata title="Northern Lights" "$demo/Northern Lights.mp4"
# The welcome's recent videos (--recents): the same picture under other names and containers.
ffmpeg -loglevel error -y -i "$demo/Northern Lights.mp4" -c copy "$demo/Lisbon Trip 2026.mp4"
ffmpeg -loglevel error -y -i "$demo/Northern Lights.mp4" -c copy "$demo/Sintel (2010).mkv"
ffmpeg -loglevel error -y -i "$demo/Northern Lights.mp4" -c copy "$demo/Tears of Steel.mov"
echo "$demo/Northern Lights.mp4"
