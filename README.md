# gearbox

Convert Euro Truck Simulator 2 save files
(`.sii` / BSII) to JSON and vice versa.

## Features

- Decodes binary (BSII) encrypted SII files
- Outputs readable JSON
- Encodes JSON output to BSII
- Single static binary, no runtime dependencies
- Linux (static musl), macOS, and Windows builds

## Install

Download the archive for your platform from the
[Releases](../../releases) page, extract it, and put `gearbox` on your `PATH`.

Verify the download:

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

## Usage

```sh
gearbox convert file game.sii json
gearbox cfj game.sii
gearbox help
```

## Build from source

Requires [Zig](https://ziglang.org/download/) 0.16.x.

```sh
git clone https://github.com/OnlyCavas/gearbox
cd gearbox
zig build -Doptimize=ReleaseSafe
./zig-out/bin/gearbox --help
```

Cross-compile, for example a static Linux binary:

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
```

## Third-party code

This project bundles [zlib](https://zlib.net) 1.3.2 (`vendor/zlib-1.3.2`),
licensed under the zlib license. See `vendor/zlib-1.3.2/LICENSE`.

## License

MIT - see [LICENSE](LICENSE).
