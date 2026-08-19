# FFmpeg for iOS

Static FFmpeg and ffprobe builds for **iOS arm64**.

The build targets jailbroken iOS devices and includes:

* H.264 / H.265
* VP8 / VP9
* AV1 decoding
* AAC, Opus, MP3 and Vorbis
* VideoToolbox hardware encoding

The binaries are statically linked and signed with `ldid`.

## Build

Requires macOS with Xcode and Homebrew.

```sh
bash scripts/build-ffmpeg-ios.sh [FFMPEG_VERSION] [IOS_MIN]
```

Example:

```sh
bash scripts/build-ffmpeg-ios.sh 8.1.2 14.0
```

The resulting binaries are placed in:

```text
artifacts/bin/
```

To create a Debian package:

```sh
bash scripts/package-deb.sh [FFMPEG_VERSION] [DEB_ARCH]
```

For example:

```sh
bash scripts/package-deb.sh 8.1.2 iphoneos-arm
```

The package is written to:

```text
artifacts/
```

The package installs `ffmpeg` and `ffprobe` under `/usr/local/bin` with `/usr/bin` symlinks.

## CI

A GitHub Actions workflow is provided for manual builds on Apple Silicon macOS runners. It builds FFmpeg and its dependencies, creates the `.deb`, and uploads the resulting artifacts.

## License

FFmpeg and the bundled third-party libraries are distributed under their respective licenses. See the FFmpeg documentation and the corresponding project licenses.
