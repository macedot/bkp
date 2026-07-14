package main

import "core:c"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

Tar_Kind :: enum {
	File,
	Dir,
	Symlink,
	Hardlink,
}

Tar_Entry :: struct {
	kind:       Tar_Kind,
	fullpath:   string,
	entry_name: string, // archive path, no leading ./ ; dirs may end with /
	link_target: string, // symlink target or hardlink path inside archive
	mode:       int,
	mtime:      i64,
	size:       i64,
	data:       []u8, // file payload only
}

// tar_directory writes src tree to dst_tgz as gzip-compressed ustar (.tgz).
// compress_workers kept for API compatibility; gzip stream is serial.
tar_directory :: proc(src_path, dst_tgz: string, compress_workers: int) -> bool {
	_ = compress_workers

	if os.exists(dst_tgz) {
		eprintfln("Error: Destination exists: %s", dst_tgz)
		return false
	}

	src := strip_trailing_slashes(src_path)
	base_name := filepath.base(src)
	if base_name == "" || base_name == "." || base_name == ".." {
		eprintfln("Error: Cannot backup '%s'", src)
		return false
	}

	entries := collect_tar_entries(src, base_name)
	if entries == nil {
		return false
	}
	defer destroy_tar_entries(entries)

	tar_buf := make([dynamic]u8)
	defer delete(tar_buf)

	for &e in entries {
		if !append_tar_entry(&tar_buf, &e) {
			eprintfln("Error: Failed to pack entry: %s", e.fullpath)
			return false
		}
	}
	// Two zero blocks end the archive.
	append_zeros(&tar_buf, 1024)

	src_ptr: [^]u8 = nil
	if len(tar_buf) > 0 {
		src_ptr = raw_data(tar_buf)
	}
	out_len: c.size_t
	gz := bkp_gzip_compress(src_ptr, c.size_t(len(tar_buf)), &out_len)
	if gz == nil {
		eprintfln("Error: gzip compress failed for %s", src)
		return false
	}
	defer bkp_free(gz)

	gz_slice := ([^]u8)(gz)[:int(out_len)]
	if err := os.write_entire_file(dst_tgz, gz_slice); err != nil {
		_ = os.remove(dst_tgz)
		eprintfln("Error: write %s: %v", dst_tgz, err)
		return false
	}
	return true
}

collect_tar_entries :: proc(src, base_name: string) -> [dynamic]Tar_Entry {
	entries := make([dynamic]Tar_Entry)

	src_abs, abs_err := os.get_absolute_path(src, context.allocator)
	if abs_err != nil {
		eprintfln("Error: resolve path %s: %v", src, abs_err)
		return nil
	}
	defer delete(src_abs)
	src_root := strip_trailing_slashes(src_abs)

	// inode -> first archive path for hardlinks
	seen_inos := make(map[u128]string)
	defer {
		for _, v in seen_inos {
			delete(v)
		}
		delete(seen_inos)
	}

	// Root directory entry.
	{
		info, err := os.lstat(src, context.allocator)
		if err != nil {
			eprintfln("Error: lstat %s: %v", src, err)
			return nil
		}
		defer os.file_info_delete(info, context.allocator)
		root_name := archive_entry_name(src_root, src_root, base_name, true)
		append(
			&entries,
			Tar_Entry {
				kind       = .Dir,
				fullpath   = strings.clone(src),
				entry_name = root_name,
				mode       = mode_from_info(info),
				mtime      = time.to_unix_seconds(info.modification_time),
			},
		)
	}

	w := os.walker_create(src)
	defer os.walker_destroy(&w)

	for info in os.walker_walk(&w) {
		if path, err := os.walker_error(&w); err != nil {
			eprintfln("Error: walking %s: %v", path, err)
			destroy_tar_entries(entries)
			return nil
		}

		fp := strip_trailing_slashes(info.fullpath)
		if fp == src_root {
			continue
		}

		// Re-lstat to avoid following symlinks.
		li, lerr := os.lstat(info.fullpath, context.allocator)
		if lerr != nil {
			eprintfln("Error: lstat %s: %v", info.fullpath, lerr)
			destroy_tar_entries(entries)
			return nil
		}
		defer os.file_info_delete(li, context.allocator)

		switch li.type {
		case .Directory:
			name := archive_entry_name(src_root, fp, base_name, true)
			append(
				&entries,
				Tar_Entry {
					kind       = .Dir,
					fullpath   = strings.clone(info.fullpath),
					entry_name = name,
					mode       = mode_from_info(li),
					mtime      = time.to_unix_seconds(li.modification_time),
				},
			)
		case .Symlink:
			target, rerr := os.read_link(info.fullpath, context.allocator)
			if rerr != nil {
				eprintfln("Error: readlink %s: %v", info.fullpath, rerr)
				destroy_tar_entries(entries)
				return nil
			}
			name := archive_entry_name(src_root, fp, base_name, false)
			append(
				&entries,
				Tar_Entry {
					kind        = .Symlink,
					fullpath    = strings.clone(info.fullpath),
					entry_name  = name,
					link_target = target,
					mode        = 0o777,
					mtime       = time.to_unix_seconds(li.modification_time),
				},
			)
		case .Regular, .Undetermined:
			name := archive_entry_name(src_root, fp, base_name, false)
			// Hardlink if inode already stored as a regular file.
			if li.inode != 0 {
				if first, ok := seen_inos[li.inode]; ok {
					append(
						&entries,
						Tar_Entry {
							kind        = .Hardlink,
							fullpath    = strings.clone(info.fullpath),
							entry_name  = name,
							link_target = strings.clone(first),
							mode        = mode_from_info(li),
							mtime       = time.to_unix_seconds(li.modification_time),
						},
					)
					break
				}
			}
			data, rerr := os.read_entire_file(info.fullpath, context.allocator)
			if rerr != nil {
				eprintfln("Error: read %s: %v", info.fullpath, rerr)
				destroy_tar_entries(entries)
				return nil
			}
			if li.inode != 0 {
				seen_inos[li.inode] = strings.clone(name)
			}
			append(
				&entries,
				Tar_Entry {
					kind       = .File,
					fullpath   = strings.clone(info.fullpath),
					entry_name = name,
					mode       = mode_from_info(li),
					mtime      = time.to_unix_seconds(li.modification_time),
					size       = i64(len(data)),
					data       = data,
				},
			)
		case .Named_Pipe, .Socket, .Block_Device, .Character_Device:
			eprintfln("Error: skipping special file: %s", info.fullpath)
		}
	}

	if path, err := os.walker_error(&w); err != nil {
		eprintfln("Error: walking %s: %v", path, err)
		destroy_tar_entries(entries)
		return nil
	}
	return entries
}

destroy_tar_entries :: proc(entries: [dynamic]Tar_Entry) {
	for &e in entries {
		delete(e.fullpath)
		delete(e.entry_name)
		delete(e.link_target)
		if e.data != nil {
			delete(e.data)
		}
	}
	delete(entries)
}

mode_from_info :: proc(info: os.File_Info) -> int {
	m := int(transmute(u32)info.mode) & 0o777
	if m == 0 {
		if info.type == .Directory {
			return 0o755
		}
		return 0o644
	}
	return m
}

append_zeros :: proc(buf: ^[dynamic]u8, n: int) {
	for i := 0; i < n; i += 1 {
		append(buf, 0)
	}
}

append_tar_entry :: proc(buf: ^[dynamic]u8, e: ^Tar_Entry) -> bool {
	name := strings.trim_right(e.entry_name, "/")
	// ustar name limit 100, prefix 155
	name_field, prefix_field, ok_split := split_ustar_name(name)
	if !ok_split {
		// Fall back: truncate with warning (rare); better than failing entirely.
		eprintfln("Error: path too long for ustar: %s", name)
		return false
	}

	typeflag: u8
	size: i64 = 0
	linkname := e.link_target

	switch e.kind {
	case .File:
		typeflag = '0'
		size = e.size
	case .Dir:
		typeflag = '5'
		// directory names often stored with trailing slash in name field
		if !strings.has_suffix(e.entry_name, "/") {
			// name_field already without slash; put slash in name if room
		}
		size = 0
	case .Symlink:
		typeflag = '2'
		size = 0
	case .Hardlink:
		typeflag = '1'
		size = 0
	}

	if len(linkname) > 100 {
		eprintfln("Error: link target too long: %s", linkname)
		return false
	}

	hdr: [512]u8
	put_str_field(hdr[0:100], name_field)
	// For directories, ensure trailing slash in name if fits
	if e.kind == .Dir {
		nf := name_field
		if !strings.has_suffix(nf, "/") && len(nf) < 100 {
			tmp := fmt_tprintf_dir_name(nf)
			put_str_field(hdr[0:100], tmp)
		}
	}
	put_octal(hdr[100:108], e.mode, 7)
	put_octal(hdr[108:116], 0, 7) // uid
	put_octal(hdr[116:124], 0, 7) // gid
	put_octal(hdr[124:136], int(size), 11)
	put_octal(hdr[136:148], int(e.mtime), 11)
	// checksum field spaces for calculation
	for i in 148 ..< 156 {
		hdr[i] = ' '
	}
	hdr[156] = typeflag
	put_str_field(hdr[157:257], linkname)
	// magic ustar\0
	copy(hdr[257:263], transmute([]u8)string("ustar\x00"))
	hdr[263] = '0'
	hdr[264] = '0'
	put_str_field(hdr[265:297], "") // uname
	put_str_field(hdr[297:329], "") // gname
	put_str_field(hdr[329:337], "")
	put_str_field(hdr[337:345], "")
	put_str_field(hdr[345:500], prefix_field)

	// checksum
	sum: uint = 0
	for b in hdr {
		sum += uint(b)
	}
	put_octal_chksum(hdr[148:156], int(sum))

	append(buf, ..hdr[:])

	if e.kind == .File && len(e.data) > 0 {
		append(buf, ..e.data)
		pad := (512 - (len(e.data) % 512)) % 512
		append_zeros(buf, pad)
	}
	return true
}

fmt_tprintf_dir_name :: proc(nf: string) -> string {
	return strings.concatenate({nf, "/"}, context.temp_allocator)
}

split_ustar_name :: proc(path: string) -> (name, prefix: string, ok: bool) {
	if len(path) <= 100 {
		return path, "", true
	}
	// Try prefix/name split on a slash so name <= 100 and prefix <= 155
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			prefix = path[:i]
			name = path[i + 1:]
			if len(name) <= 100 && len(prefix) <= 155 && len(name) > 0 {
				return name, prefix, true
			}
		}
	}
	return "", "", false
}

put_str_field :: proc(dst: []u8, s: string) {
	for i in 0 ..< len(dst) {
		dst[i] = 0
	}
	n := min(len(s), len(dst))
	for i in 0 ..< n {
		dst[i] = s[i]
	}
}

// put_octal writes NUL-terminated octal into field of width (standard tar style).
put_octal :: proc(dst: []u8, value: int, digits: int) {
	for i in 0 ..< len(dst) {
		dst[i] = 0
	}
	// format as octal with leading zeros, leave last as NUL if room
	buf: [32]u8
	n := format_octal(buf[:], value, digits)
	// copy into dst: digits chars + NUL
	for i in 0 ..< min(n, len(dst) - 1) {
		dst[i] = buf[i]
	}
	if n < len(dst) {
		dst[n] = 0
	}
}

put_octal_chksum :: proc(dst: []u8, value: int) {
	// 6 octal digits, NUL, space
	for i in 0 ..< len(dst) {
		dst[i] = ' '
	}
	buf: [32]u8
	n := format_octal(buf[:], value, 6)
	for i in 0 ..< min(6, n) {
		dst[i] = buf[i]
	}
	dst[6] = 0
	dst[7] = ' '
}

format_octal :: proc(buf: []u8, value: int, width: int) -> int {
	// produce zero-padded octal string of exactly `width` digits when possible
	v := value
	if v < 0 {
		v = 0
	}
	// write from end
	tmp: [32]u8
	i := 0
	if v == 0 {
		tmp[0] = '0'
		i = 1
	} else {
		for v > 0 && i < len(tmp) {
			tmp[i] = u8('0' + (v & 7))
			v >>= 3
			i += 1
		}
	}
	// reverse into out with padding
	out_len := max(width, i)
	if out_len > len(buf) {
		out_len = len(buf)
	}
	for j in 0 ..< out_len {
		buf[j] = '0'
	}
	for j in 0 ..< i {
		buf[out_len - 1 - j] = tmp[j]
	}
	// if width specified, return width
	if width > 0 {
		return min(width, len(buf))
	}
	return out_len
}
