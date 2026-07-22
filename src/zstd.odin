package main

import "core:c"

when ODIN_OS == .Windows {
	foreign import bkpzstd {
		"../build/bkpzstd.lib",
	}
} else {
	foreign import bkpzstd {
		"../build/libbkpzstd.a",
	}
}

@(default_calling_convention = "c")
foreign bkpzstd {
	bkp_zstd_compress :: proc(
		src: [^]u8,
		src_len: c.size_t,
		level: c.int,
		workers: c.int,
		out_len: ^c.size_t,
	) -> [^]u8 ---

	bkp_zstd_decompress :: proc(
		src: [^]u8,
		src_len: c.size_t,
		out_len: ^c.size_t,
	) -> [^]u8 ---

	bkp_zstd_frame_compressed_size :: proc(src: [^]u8, src_len: c.size_t) -> c.size_t ---

	bkp_zstd_frame_content_size :: proc(src: [^]u8, src_len: c.size_t) -> c.size_t ---

	bkp_zstd_decompress_into :: proc(
		src: [^]u8,
		src_len: c.size_t,
		dst: [^]u8,
		dst_cap: c.size_t,
		out_len: ^c.size_t,
	) -> c.int ---

	bkp_free :: proc(p: rawptr) ---
}
