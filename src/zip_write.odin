package main

import "core:c"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"

Zip_Entry_Kind :: enum {
	File,
	Dir,
}

Zip_Entry :: struct {
	kind:       Zip_Entry_Kind,
	fullpath:   string, // absolute/local path on disk
	entry_name: string, // path inside archive (forward slashes)
	// Filled by compress workers for files:
	data:       []u8, // original file bytes (owned)
	comp:       [^]u8, // miniz-allocated compressed bytes (or nil if stored)
	comp_len:   int,
	crc:        u32,
	use_store:  bool,
	err:        bool,
}

// zip_directory creates dst_zip from directory src_path using DEFLATE level 1.
// compress_workers controls parallel file compression.
zip_directory :: proc(src_path, dst_zip: string, compress_workers: int) -> bool {
	if os.exists(dst_zip) {
		eprintfln("Error: Destination exists: %s", dst_zip)
		return false
	}

	src := strip_trailing_slashes(src_path)
	base_name := filepath.base(src)
	if base_name == "" || base_name == "." || base_name == ".." {
		eprintfln("Error: Cannot backup '%s'", src)
		return false
	}

	entries := collect_zip_entries(src, base_name)
	if entries == nil {
		return false
	}
	defer destroy_zip_entries(entries)

	// Parallel compress file entries.
	n_workers := max(1, compress_workers)
	compress_file_entries(entries, n_workers)

	for e in entries {
		if e.err {
			eprintfln("Error: Failed to prepare entry: %s", e.fullpath)
			return false
		}
	}

	// Assemble ZIP serially via miniz.
	dst_c := strings.clone_to_cstring(dst_zip)
	defer delete(dst_c)

	z := bkp_zip_open(dst_c)
	if z == nil {
		eprintfln("Error: Cannot create zip: %s", dst_zip)
		return false
	}

	ok := true
	for &e in entries {
		name_c := strings.clone_to_cstring(e.entry_name)
		if e.kind == .Dir {
			if bkp_zip_add_dir(z, name_c) == 0 {
				ok = false
			}
		} else if e.use_store || e.comp == nil {
			data_ptr: rawptr = nil
			if len(e.data) > 0 {
				data_ptr = raw_data(e.data)
			}
			if bkp_zip_add_stored(z, name_c, data_ptr, c.size_t(len(e.data)), c.uint(e.crc)) == 0 {
				ok = false
			}
		} else {
			if bkp_zip_add_precompressed(
				   z,
				   name_c,
				   e.comp,
				   c.size_t(e.comp_len),
				   c.size_t(len(e.data)),
				   c.uint(e.crc),
			   ) ==
			   0 {
				ok = false
			}
		}
		delete(name_c)
		if !ok {
			break
		}
	}

	if !ok {
		bkp_zip_abort(z)
		_ = os.remove(dst_zip)
		eprintfln("Error: Failed writing zip: %s", dst_zip)
		return false
	}

	if bkp_zip_close(z) == 0 {
		_ = os.remove(dst_zip)
		eprintfln("Error: Failed finalizing zip: %s", dst_zip)
		return false
	}
	return true
}

collect_zip_entries :: proc(src, base_name: string) -> [dynamic]Zip_Entry {
	entries := make([dynamic]Zip_Entry)

	// Walker yields absolute fullpaths; normalize src the same way so relative
	// prefixes match (e.g. "dir/sub/b.txt" stays under "dir/", not just "b.txt").
	src_abs, abs_err := os.get_absolute_path(src, context.allocator)
	if abs_err != nil {
		eprintfln("Error: resolve path %s: %v", src, abs_err)
		return nil
	}
	defer delete(src_abs)
	src_root := strip_trailing_slashes(src_abs)

	// Root directory entry so unzip recreates the folder.
	root_name := archive_entry_name(src_root, src_root, base_name, true)
	append(
		&entries,
		Zip_Entry{kind = .Dir, fullpath = strings.clone(src), entry_name = root_name},
	)

	w := os.walker_create(src)
	defer os.walker_destroy(&w)

	for info in os.walker_walk(&w) {
		if path, err := os.walker_error(&w); err != nil {
			eprintfln("Error: walking %s: %v", path, err)
			destroy_zip_entries(entries)
			return nil
		}

		is_dir := info.type == .Directory
		is_file := info.type == .Regular || info.type == .Symlink || info.type == .Undetermined

		if !is_dir && !is_file {
			// Skip sockets, devices, etc.
			continue
		}

		fp := strip_trailing_slashes(info.fullpath)

		// Skip the root itself if walker yields it.
		if fp == src_root {
			continue
		}

		name := archive_entry_name(src_root, fp, base_name, is_dir)
		entry := Zip_Entry {
			kind       = is_dir ? .Dir : .File,
			fullpath   = strings.clone(info.fullpath),
			entry_name = name,
		}
		append(&entries, entry)
	}

	if path, err := os.walker_error(&w); err != nil {
		eprintfln("Error: walking %s: %v", path, err)
		destroy_zip_entries(entries)
		return nil
	}

	return entries
}

destroy_zip_entries :: proc(entries: [dynamic]Zip_Entry) {
	for &e in entries {
		delete(e.fullpath)
		delete(e.entry_name)
		if e.data != nil {
			delete(e.data)
		}
		if e.comp != nil {
			bkp_free(e.comp)
			e.comp = nil
		}
	}
	delete(entries)
}

compress_file_entries :: proc(entries: [dynamic]Zip_Entry, n_workers: int) {
	// Count files needing compression.
	file_indices := make([dynamic]int)
	defer delete(file_indices)
	for e, i in entries {
		if e.kind == .File {
			append(&file_indices, i)
		}
	}
	if len(file_indices) == 0 {
		return
	}

	n_workers := min(n_workers, len(file_indices))
	n_workers = max(1, n_workers)

	// Thread-safe heap allocator for tasks.
	pool: thread.Pool
	thread.pool_init(&pool, context.allocator, n_workers)
	defer thread.pool_destroy(&pool)

	// Each task gets a pointer to Zip_Entry inside the dynamic array.
	// Safe: we only mutate distinct entries; no reallocation during compress.
	for idx in file_indices {
		e := &entries[idx]
		thread.pool_add_task(&pool, context.allocator, compress_one_task, e, idx)
	}

	thread.pool_start(&pool)
	thread.pool_finish(&pool)
}

compress_one_task :: proc(t: thread.Task) {
	e := cast(^Zip_Entry)t.data
	data, rerr := os.read_entire_file(e.fullpath, context.allocator)
	if rerr != nil {
		e.err = true
		return
	}
	e.data = data

	// Empty file → store.
	if len(data) == 0 {
		e.use_store = true
		e.crc = 0
		return
	}

	out_len: c.size_t
	crc: c.uint
	comp := bkp_deflate(raw_data(data), c.size_t(len(data)), &out_len, &crc)
	if comp == nil {
		// Fall back to store on compress failure.
		e.use_store = true
		e.crc = u32(crc)
		return
	}

	e.crc = u32(crc)
	// If deflate did not shrink, store raw (faster extract, smaller or equal size).
	if int(out_len) >= len(data) {
		bkp_free(comp)
		e.use_store = true
		return
	}

	e.comp = comp
	e.comp_len = int(out_len)
	e.use_store = false
}
