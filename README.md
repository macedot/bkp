# bkp

Standalone Odin tool for timestamped backups:

- **File** → copy to `<path>.<timestamp>`
- **Directory** → ZIP to `<path>.<timestamp>.zip` (DEFLATE level 1, `unzip`-compatible)

No runtime dependencies (embeds [miniz](https://github.com/richgel999/miniz) for compression).

## Build

Requires [Odin](https://odin-lang.org/docs/install/) and a C compiler (`cc`).

```bash
make
```

Produces `./bkp`.

## Usage

```
bkp [-j N] [-c N] <file|directory|pattern> ...

  -j N   Max entities to process in parallel (default: CPU count)
  -c N   Cores for DEFLATE inside each zip (default: CPU count)
```

No arguments prints usage and exits with code `2`.

Stdout prints only:

```
src -> dst
```

Errors go to stderr. Exit `1` if any entity fails.

### Examples

```bash
./bkp notes.txt src/
./bkp -j 4 -c 8 data/*.csv project/
```

## Test

```bash
make test
```

## Releases

Publishing a GitHub Release runs [`.github/workflows/release.yml`](.github/workflows/release.yml) and attaches binaries for:

| Asset | Platform |
|-------|----------|
| `bkp-linux-amd64` | Linux x86_64 |
| `bkp-linux-arm64` | Linux ARM64 |
| `bkp-darwin-arm64` | macOS Apple Silicon |
| `bkp-windows-amd64.exe` | Windows x86_64 |

## Layout

| Path | Role |
|------|------|
| `src/` | Odin sources |
| `vendor/miniz.*` | Embedded DEFLATE/ZIP (amalgamation) |
| `vendor/bkp_miniz_wrap.c` | Thin C API used from Odin |
| `build/` | Object files / static lib (not tracked) |
| `.github/workflows/` | Release multi-arch builds |
