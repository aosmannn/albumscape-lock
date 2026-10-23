#!/bin/zsh
# Turns the pictures `AlbumscapeLock --record <folder> ...` wrote into a web clip and a poster.
#   tools/make-clip.sh <frames-folder> <out-name> [width]   ->  <out-name>.mp4 and <out-name>.jpg
set -e
F="$1"; OUT="$2"; W="${3:-1920}"
ffmpeg -loglevel error -y -framerate 20 -i "$F/f%04d.jpg" -vf "scale=$W:-2" -c:v libx264 -preset slow -crf 24 -pix_fmt yuv420p -movflags +faststart -an "$OUT.mp4"
ffmpeg -loglevel error -y -i "$F/f0020.jpg" -vf "scale=$W:-2" -q:v 3 "$OUT.jpg"
echo "$OUT.mp4 $OUT.jpg"
