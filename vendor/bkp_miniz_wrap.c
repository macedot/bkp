/*
 * Thin C wrapper around miniz for bkp:
 * - gzip compress (level 1 / MZ_BEST_SPEED) for .tgz
 * - free helper
 */
#include "miniz.h"
#include <stdlib.h>
#include <string.h>

/* Compress to gzip (RFC 1952) with DEFLATE level 1.
 * Returns malloc'd buffer (free with bkp_free). NULL on failure.
 */
unsigned char *bkp_gzip_compress(const unsigned char *src, size_t src_len, size_t *out_len)
{
	mz_uint  flags;
	void    *raw;
	size_t   raw_len = 0;
	size_t   total;
	unsigned char *out;
	mz_ulong crc;
	size_t   off;
	mz_uint32 isize;

	if (!out_len)
		return NULL;
	*out_len = 0;

	flags = tdefl_create_comp_flags_from_zip_params(
		MZ_BEST_SPEED, -MZ_DEFAULT_WINDOW_BITS, MZ_DEFAULT_STRATEGY);

	raw = tdefl_compress_mem_to_heap(src ? src : (const unsigned char *)"", src_len, &raw_len, (int)flags);
	if (!raw)
		return NULL;

	total = 10 + raw_len + 8;
	out = (unsigned char *)malloc(total);
	if (!out) {
		mz_free(raw);
		return NULL;
	}

	/* gzip header: ID1 ID2 CM FLG MTIME(4) XFL OS */
	out[0] = 0x1f;
	out[1] = 0x8b;
	out[2] = 8; /* CM = deflate */
	out[3] = 0; /* FLG */
	out[4] = out[5] = out[6] = out[7] = 0; /* MTIME */
	out[8] = 4; /* XFL = fastest */
	out[9] = 3; /* OS = Unix */

	memcpy(out + 10, raw, raw_len);
	mz_free(raw);

	crc = mz_crc32(MZ_CRC32_INIT, src, src_len);
	isize = (mz_uint32)(src_len & 0xffffffffu);
	off = 10 + raw_len;
	out[off + 0] = (unsigned char)(crc & 0xff);
	out[off + 1] = (unsigned char)((crc >> 8) & 0xff);
	out[off + 2] = (unsigned char)((crc >> 16) & 0xff);
	out[off + 3] = (unsigned char)((crc >> 24) & 0xff);
	out[off + 4] = (unsigned char)(isize & 0xff);
	out[off + 5] = (unsigned char)((isize >> 8) & 0xff);
	out[off + 6] = (unsigned char)((isize >> 16) & 0xff);
	out[off + 7] = (unsigned char)((isize >> 24) & 0xff);

	*out_len = total;
	return out;
}

void bkp_free(void *p)
{
	if (p)
		free(p);
}
