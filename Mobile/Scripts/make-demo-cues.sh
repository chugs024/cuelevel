#!/bin/zsh
# Builds a small example show (synthesised, no recordings) for simulator screenshots and tests.
# Usage: Mobile/Scripts/make-demo-cues.sh <ffmpeg> <folder>
set -euo pipefail
FF="$1"; OUT="$2"; mkdir -p "$OUT"
q=(-hide_banner -loglevel error -y)
# Walk-in music: steady tones, quiet.
"$FF" $q -f lavfi -i "aevalsrc='0.08*sin(2*PI*220*t)*(0.7+0.3*sin(2*PI*0.2*t))+0.04*sin(2*PI*660*t)|0.08*sin(2*PI*330*t)*(0.7+0.3*cos(2*PI*0.2*t))+0.04*sin(2*PI*990*t)':s=48000:d=40" -c:a pcm_s24le "$OUT/01 Walk-in music.wav"
# Host and guest: speech-like phrases, the guest 9 dB down in the middle.
"$FF" $q -f lavfi -i "anoisesrc=color=pink:sample_rate=48000:duration=45:seed=3" -af "lowpass=f=3500,volume='if(lt(mod(t,2.6),1.9),0.35,0.004)':eval=frame,volume=-9dB:enable='between(t,15,29)'" -ac 2 -c:a pcm_s24le "$OUT/02 Host welcome and guest.wav"
# Sponsor reel: a short video already near the target.
"$FF" $q -f lavfi -i "testsrc2=s=1280x720:r=25:d=8" -f lavfi -i "anoisesrc=color=pink:sample_rate=48000:duration=8:seed=5" -af "volume=-20dB" -c:v mpeg4 -q:v 4 -c:a aac -b:a 192k -shortest "$OUT/03 Sponsor reel.mov"
# Award sting: hot.
"$FF" $q -f lavfi -i "aevalsrc='0.9*sin(2*PI*440*t)*exp(-1.5*mod(t,2))|0.9*sin(2*PI*554*t)*exp(-1.5*mod(t,2))':s=44100:d=12" -c:a pcm_s16le "$OUT/04 Award sting.wav"
# Reflection piano: very quiet.
"$FF" $q -f lavfi -i "aevalsrc='0.02*sin(2*PI*262*t)*exp(-0.8*mod(t,1.5))+0.015*sin(2*PI*392*t)*exp(-0.8*mod(t+0.5,1.5))':s=48000:d=30" -ac 2 -c:a aac -b:a 256k "$OUT/05 Reflection piano.m4a"
ls -la "$OUT"
