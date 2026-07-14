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

@(default_calling_convention = "c")
foreign bkpminiz {
	bkp_gzip_compress :: proc(
		src: [^]u8,
		src_len: c.size_t,
		out_len: ^c.size_t,
	) -> [^]u8 ---

	bkp_free :: proc(p: rawptr) ---
}
