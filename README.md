# bkp

Standalone Odin tool for timestamped backups and extract:

- **File** → copy to `<path>.<timestamp>`
- **Directory** → `<path>.<timestamp>.tgz` (ustar + gzip level 1, **symlinks & hardlinks**)
- **Extract** → `bkp -x archive.tgz [dest]`

No runtime compression libraries (embeds [miniz](https://github.com/richgel999/miniz) for gzip). Gunzip on extract uses Odin `core:compress/gzip`.

## Build

Requires [Odin](https://odin-lang.org/docs/install/) and a C compiler (`cc`).

```bash
make
```

Produces `./bkp`.

## Usage

```
bkp [-j N] [-c N] <file|directory|pattern> ...
bkp -x <archive.tgz> [dest_dir]

  -j N   Max entities to process in parallel (default: CPU count)
  -c N   Entry-prep parallelism while packing (default: CPU count)
         gzip stream itself is serial

  Files:  copy to <path>.<timestamp>
  Dirs:   pack to <path>.<timestamp>.tgz
  -x:     unpack .tgz / .tar.gz into dest_dir (default: .)
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
./bkp -x project.20260714120000.tgz restored/
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
| `vendor/miniz.*` | Embedded DEFLATE/gzip |
| `vendor/bkp_miniz_wrap.c` | Thin C API used from Odin |
| `build/` | Object files / static lib (not tracked) |
| `.github/workflows/` | Release multi-arch builds |
