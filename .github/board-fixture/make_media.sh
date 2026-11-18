#!/usr/bin/env bash
# 2026-11-18 — generated test media (no real content): 1080×1920 H.264 test patterns with noise, so the encoder
# really reaches the target bitrate; photos 4000×3000 JPEG; animated GIFs 480×480.
set -euo pipefail
mkdir -p media
cd media
# 30 × 2.5 Mbit/s (≈4.5 MB, like the board's web versions)
for i in $(seq -w 1 30); do
  ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1080x1920:rate=24:duration=14.5" -f lavfi -i "sine=frequency=$((300 + 10#$i * 20)):duration=14.5" \
    -vf "noise=alls=12:allf=t,drawtext=text='V$i':fontsize=200:x=60:y=60:fontcolor=white" -c:v libx264 -preset veryfast \
    -b:v 2500k -maxrate 2500k -bufsize 5000k -pix_fmt yuv420p -c:a aac -b:a 96k -movflags +faststart "v25-$i.mp4"
done
# 2 × 15 Mbit/s originals (≈27 MB)
for i in 1 2; do
  ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1080x1920:rate=24:duration=14.5" -f lavfi -i "sine=frequency=$((800 + i * 50)):duration=14.5" \
    -vf "noise=alls=40:allf=t+u,drawtext=text='O$i':fontsize=200:x=60:y=60:fontcolor=white" -c:v libx264 -preset veryfast \
    -b:v 15000k -minrate 15000k -maxrate 15000k -bufsize 30000k -pix_fmt yuv420p -c:a aac -b:a 128k "v15-$i.mp4"
done
# 60 photos 4000×3000
for i in $(seq -w 1 60); do
  ffmpeg -loglevel error -y -f lavfi -i "mandelbrot=size=4000x3000:start_scale=$((10#$i % 7 + 1)):end_pts=1" -frames:v 1 -q:v 4 "p-$i.jpg"
done
# 10 GIFs
for i in $(seq -w 1 10); do
  ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=480x480:rate=15:duration=3" -vf "hue=h=$((10#$i * 36))" "g-$i.gif"
done
ls -la | awk '{s+=$5} END {print "total MB", s/1e6}'
for f in v25-01.mp4 v15-1.mp4; do ffprobe -v error -select_streams v:0 -show_entries stream=width,height,bit_rate -show_entries format=size -of csv=p=0 "$f"; done
