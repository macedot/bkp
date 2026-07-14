package main

import "core:bytes"
import "core:compress/gzip"
import "core:os"
import "core:path/filepath"
import "core:strings"

// extract_tgz unpacks a gzip-compressed tar into dest_dir.
// Prints archive -> dest on success via caller.
extract_tgz :: proc(archive, dest_dir: string) -> bool {
	if !os.exists(archive) {
		eprintfln("Error: Not found: %s", archive)
		return false
	}

	dest := dest_dir
	if dest == "" {
		dest = "."
	}

	if err := os.make_directory_all(dest); err != nil && !os.exists(dest) {
		eprintfln("Error: mkdir %s: %v", dest, err)
		return false
	}

	gz_data, rerr := os.read_entire_file(archive, context.allocator)
	if rerr != nil {
		eprintfln("Error: read %s: %v", archive, rerr)
		return false
	}
	defer delete(gz_data)

	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	if gerr := gzip.load(data = gz_data, buf = &buf); gerr != nil {
		eprintfln("Error: gunzip %s: %v", archive, gerr)
		return false
	}

	tar_data := bytes.buffer_to_bytes(&buf)
	return extract_tar_bytes(tar_data, dest)
}

extract_tar_bytes :: proc(data: []u8, dest_dir: string) -> bool {
	off := 0
	for off + 512 <= len(data) {
		hdr := data[off:off + 512]
		off += 512

		if is_zero_block(hdr) {
			// End of archive (one or two zero blocks)
			if off + 512 <= len(data) && is_zero_block(data[off:off + 512]) {
				return true
			}
			return true
		}

		name := ustar_full_name(hdr)
		if name == "" {
			eprintfln("Error: empty tar member name")
			return false
		}

		typeflag := hdr[156]
		size := parse_octal(hdr[124:136])
		linkname := cstr_field(hdr[157:257])
		mode := parse_octal(hdr[100:108])

		// Consume payload + padding
		payload: []u8
		if size > 0 {
			if off + int(size) > len(data) {
				eprintfln("Error: truncated tar payload for %s", name)
				return false
			}
			payload = data[off:off + int(size)]
			off += int(size)
			pad := (512 - (int(size) % 512)) % 512
			off += pad
		}

		// pax / gnu long name — minimal: skip unsupported special types with data
		if typeflag == 'x' || typeflag == 'g' || typeflag == 'L' || typeflag == 'K' {
			// skip extended headers for v1 if we didn't write them
			continue
		}

		safe, ok := safe_join(dest_dir, name)
		if !ok {
			eprintfln("Error: unsafe path in archive: %s", name)
			return false
		}

		switch typeflag {
		case '5', 'D':
			// directory
			if err := os.make_directory_all(safe, perm_from_mode(mode, true)); err != nil &&
			   !os.is_directory(safe) {
				eprintfln("Error: mkdir %s: %v", safe, err)
				return false
			}
		case '2':
			// symlink
			parent := filepath.dir(safe)
			_ = os.make_directory_all(parent)
			if os.exists(safe) {
				_ = os.remove(safe)
			}
			if err := os.symlink(linkname, safe); err != nil {
				eprintfln("Error: symlink %s -> %s: %v", safe, linkname, err)
				return false
			}
		case '1':
			// hardlink
			target, tok := safe_join(dest_dir, linkname)
			if !tok {
				eprintfln("Error: unsafe hardlink target: %s", linkname)
				return false
			}
			parent := filepath.dir(safe)
			_ = os.make_directory_all(parent)
			if os.exists(safe) {
				_ = os.remove(safe)
			}
			if err := os.link(target, safe); err != nil {
				eprintfln("Error: link %s -> %s: %v", safe, target, err)
				return false
			}
		case '0', '\x00', '7':
			// regular file
			parent := filepath.dir(safe)
			if err := os.make_directory_all(parent); err != nil && !os.is_directory(parent) {
				eprintfln("Error: mkdir %s: %v", parent, err)
				return false
			}
			if err := os.write_entire_file(safe, payload, perm_from_mode(mode, false)); err != nil {
				eprintfln("Error: write %s: %v", safe, err)
				return false
			}
		case:
			// ignore other types
			continue
		}
	}
	return true
}

is_zero_block :: proc(b: []u8) -> bool {
	for x in b {
		if x != 0 {
			return false
		}
	}
	return true
}

cstr_field :: proc(b: []u8) -> string {
	n := 0
	for n < len(b) && b[n] != 0 {
		n += 1
	}
	return string(b[:n])
}

ustar_full_name :: proc(hdr: []u8) -> string {
	name := cstr_field(hdr[0:100])
	prefix := cstr_field(hdr[345:500])
	if prefix == "" {
		return strings.clone(strings.trim_right(name, "/"))
	}
	return strings.clone(
		strings.trim_right(strings.concatenate({prefix, "/", name}, context.temp_allocator), "/"),
	)
}

parse_octal :: proc(b: []u8) -> i64 {
	s := cstr_field(b)
	s = strings.trim_space(s)
	if s == "" {
		return 0
	}
	v: i64 = 0
	for i in 0 ..< len(s) {
		c := s[i]
		if c < '0' || c > '7' {
			break
		}
		v = v * 8 + i64(c - '0')
	}
	return v
}

// safe_join ensures result stays under dest_dir (no absolute / no ..).
safe_join :: proc(dest_dir, name: string) -> (string, bool) {
	n := name
	// strip leading slashes
	for len(n) > 0 && (n[0] == '/' || n[0] == '\\') {
		n = n[1:]
	}
	if n == "" {
		return "", false
	}
	// normalize and reject ..
	parts := strings.split(n, "/")
	defer delete(parts)
	clean := make([dynamic]string)
	defer delete(clean)
	for p in parts {
		if p == "" || p == "." {
			continue
		}
		if p == ".." {
			return "", false
		}
		// also reject backslash segments on unix
		if strings.contains(p, "\\") {
			return "", false
		}
		append(&clean, p)
	}
	if len(clean) == 0 {
		return "", false
	}
	joined := strings.join(clean[:], "/")
	defer delete(joined)
	full, jerr := filepath.join([]string{dest_dir, joined})
	if jerr != nil {
		return "", false
	}
	return full, true
}

perm_from_mode :: proc(mode: i64, is_dir: bool) -> os.Permissions {
	m := int(mode) & 0o777
	if m == 0 {
		if is_dir {
			return os.Permissions_Default_Directory
		}
		return os.Permissions_Default_File
	}
	return os.perm_number(m)
}
