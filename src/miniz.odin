package main

import "core:c"

when ODIN_OS == .Windows {
	foreign import bkpminiz {
		"../build/bkpminiz.lib",
	}
} else {
	foreign import bkpminiz {
		"../build/libbkpminiz.a",
	}
}

Bkp_Zip :: struct {}

@(default_calling_convention = "c")
foreign bkpminiz {
	bkp_deflate :: proc(
		src: [^]u8,
		src_len: c.size_t,
		out_len: ^c.size_t,
		crc_out: ^c.uint,
	) -> [^]u8 ---

	bkp_free :: proc(p: rawptr) ---

	bkp_zip_open :: proc(path: cstring) -> ^Bkp_Zip ---

	bkp_zip_add_precompressed :: proc(
		z: ^Bkp_Zip,
		name: cstring,
		comp: rawptr,
		comp_len: c.size_t,
		uncomp_len: c.size_t,
		crc: c.uint,
	) -> c.int ---

	bkp_zip_add_stored :: proc(
		z: ^Bkp_Zip,
		name: cstring,
		buf: rawptr,
		len: c.size_t,
		crc: c.uint,
	) -> c.int ---

	bkp_zip_add_dir :: proc(z: ^Bkp_Zip, name: cstring) -> c.int ---

	bkp_zip_close :: proc(z: ^Bkp_Zip) -> c.int ---

	bkp_zip_abort :: proc(z: ^Bkp_Zip) ---
}
