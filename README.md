<h1 align="center">bkp</h1>

<p align="center"><strong>Standalone timestamped backups — files, folders, symlinks, hardlinks</strong></p>

<p align="center">
  <img src="https://img.shields.io/github/license/macedot/bkp?color=blue" alt="License" />
  <img src="https://img.shields.io/badge/Odin-dev--2026-blueviolet" alt="Odin" />
  <img src="https://img.shields.io/badge/platform-linux%20%7C%20macOS%20%7C%20windows-lightgrey" alt="Platforms" />
  <img src="https://img.shields.io/github/v/release/macedot/bkp?display_name=tag" alt="Release" />
</p>

---

**bkp** is a small, dependency-free CLI for fast local backups. Point it at files or directories and get timestamped copies: plain files are duplicated beside the original; directories become a single **`.tgz`** (ustar + gzip) that preserves **symlinks** and **hardlinks**. Unpack with `bkp -x` or standard `tar`.

Written in [Odin](https://odin-lang.org/). Compression uses an embedded [miniz](https://github.com/richgel999/miniz) (gzip level 1). No system `zlib`, `pigz`, or `zip` required at runtime.

## Features

- **Timestamped file copies** — `notes.txt` → `notes.txt.20260714120000` (like `cp -p`)
- **Directory archives** — `project/` → `project.20260714120000.tgz`
- **Symlinks & hardlinks** — stored correctly in the tar stream (not flattened as ZIP often is)
- **Extract mode** — `bkp -x archive.tgz [dest]` restores files, dirs, and links safely
- **Parallel entities** — `-j` processes multiple top-level paths at once
- **Folder pack progress** — live single-line progress while building `.tgz`
- **Quiet mode** — `--quiet` suppresses non-error output
- **Multi-arch releases** — Linux amd64/arm64, macOS Apple Silicon, Windows amd64

## Quick Start

### Pre-built binary

Download from [Releases](https://github.com/macedot/bkp/releases/latest), then:

```bash
chmod +x bkp-linux-amd64   # or the asset for your OS
./bkp-linux-amd64 notes.txt src/
```

### Build from source

Requires [Odin](https://odin-lang.org/docs/install/) and a C compiler (`cc` / MSVC on Windows).

```bash
git clone https://github.com/macedot/bkp.git
cd bkp
make
./bkp
```

## Usage

```
bkp [--quiet] [-j N] [-c N] <file|directory|pattern> ...
bkp -x <archive.tgz> [dest_dir]
```

| Mode | Behavior |
|------|----------|
| **File** | Copy to `<path>.<timestamp>` |
| **Directory** | Pack to `<path>.<timestamp>.tgz` (ustar + gzip level 1) |
| **`-x`** | Unpack `.tgz` / `.tar.gz` into `dest_dir` (default: `.`) |

| Flag | Default | Description |
|------|---------|-------------|
| `-j N` | CPU count | Max paths to process in parallel |
| `-c N` | CPU count | Entry-prep workers while packing (gzip stream is serial) |
| `--quiet` | off | Suppress all non-error output (progress + `src -> dst`) |

No arguments prints usage and exits with code `2`. Exit `1` if any path fails.

In default mode, stdout shows live single-line folder packing progress plus mapping lines:

```
src -> dst
```

Use `--quiet` to keep stdout empty unless an error occurs (errors still go to stderr).

### Examples

```bash
# Backup a file and a tree
./bkp notes.txt src/

# Parallel jobs
./bkp -j 4 -c 8 data/*.csv project/

# Shell globs (or let bkp expand patterns)
./bkp 'logs/*.log'

# Extract
./bkp -x project.20260714120000.tgz restored/

# Compatible with system tar
tar -tzf project.20260714120000.tgz
tar -xzf project.20260714120000.tgz -C restored/
```

## How it works

| Input | Output |
|-------|--------|
| Regular file | Byte copy next to the source, suffix `.<YYYYMMDDHHMMSS>` |
| Directory | Walk with `lstat` → ustar members (`0` file, `5` dir, `2` symlink, `1` hardlink) → gzip → `.tgz` |

Hardlinks share an inode: the first copy stores data; later names reference it. Symlinks store the link target, not the pointed-to content.

Extract rejects path traversal (`..`, absolute names) before writing under the destination.

## Test

```bash
make test
```

Covers file copy, nested tree, symlink, hardlink, `tar -tzf`, and `bkp -x`.

## Releases

Publishing a GitHub Release runs [`.github/workflows/release.yml`](.github/workflows/release.yml) and attaches:

| Asset | Platform |
|-------|----------|
| `bkp-linux-amd64.tar.gz` | Linux x86_64 |
| `bkp-linux-arm64.tar.gz` | Linux ARM64 |
| `bkp-darwin-arm64.tar.gz` | macOS Apple Silicon |
| `bkp-windows-amd64.zip` | Windows x86_64 |

## Layout

| Path | Role |
|------|------|
| `src/` | Odin sources (CLI, tar write/read, copy) |
| `vendor/miniz.*` | Embedded DEFLATE / gzip |
| `vendor/bkp_miniz_wrap.c` | Thin C API used from Odin |
| `build/` | Local objects / static lib (not tracked) |
| `.github/workflows/` | Multi-arch release builds |

## License

**bkp** is licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).

Bundled [miniz](https://github.com/richgel999/miniz) retains its own license (see `vendor/MINIZ_LICENSE`).
