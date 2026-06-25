# LiteReplayd

Tools for introspecting iOS **ReplayKit / `replayd`** screen recording and
reducing its (very large) output file size, plus a reproducible build of a
modern **FFmpeg for jailbroken iOS arm64**.

## Why

ReplayKit records the screen as **H.264 (`avc1`) at ~16.9 Mbit/s, 60 fps** via
`AVAssetWriter` — roughly **7 GB/hour**. Re-encoding to **HEVC** gives the same
perceptual quality at about half the bitrate. The device already has Apple's
hardware `hevc_videotoolbox` encoder; this repo provides the tooling to observe
the encoder settings and to measure/produce smaller files.

## Layout

```
.github/workflows/build-ffmpeg-ios.yml   CI: cross-compile + package FFmpeg
scripts/
  build-ffmpeg-ios.sh                     cross-compile static FFmpeg (macOS runner)
  package-deb.sh                          wrap binaries into an installable .deb
frida/
  introspect-encoder.js                   observe replayd's encoder settings
  patch-hevc.js                           rewrite AVAssetWriter dict -> HEVC at runtime
tools/
  mp4probe.py                             MP4 codec/bitrate inspector (no ffmpeg needed)
```

## Build FFmpeg

Push to GitHub and run the **Build FFmpeg for iOS (arm64)** workflow
(Actions tab → Run workflow). Inputs: `ffmpeg_version`, `ios_min`, `deb_arch`
(match `dpkg --print-architecture` on the device — `iphoneos-arm` for
checkra1n/unc0ver, `iphoneos-arm64`/`-arm64e` for Procursus).

The artifact contains signed `bin/{ffmpeg,ffprobe}`, the static `lib/`+`include/`,
and `ffmpeg-static_<ver>_<arch>.deb`.

Install on the device:

```sh
scp ffmpeg-static_*.deb root@DEVICE:/tmp/
ssh root@DEVICE 'dpkg -i /tmp/ffmpeg-static_*.deb && ffmpeg -version | head -1'
```

The build is self-verifying: it checks the Mach-O platform of every dependency
archive (catching macOS-vs-iOS object mismatches), dumps build logs on failure,
and introspects the final binaries.

## Frida introspection

On a jailbroken device with `frida-server`:

```sh
frida -U -n replayd -l frida/introspect-encoder.js   # observe settings
frida -U -n replayd -l frida/patch-hevc.js           # force HEVC at capture time
```

## Analyze a recording

```sh
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,bit_rate \
  -show_entries format=duration,size -of default=nw=1 FILE.mp4
# or, without ffmpeg:
python3 tools/mp4probe.py FILE.mp4
```
