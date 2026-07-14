/*
 * Thin C wrapper around miniz for the bkp tool.
 * Provides: raw DEFLATE (level 1), CRC32, and sequential ZIP writing
 * so Odin can pre-compress files in parallel then assemble the archive.
 */
#include "miniz.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
	mz_zip_archive zip;
	int            finalized;
} Bkp_Zip;

/* Compress src with raw DEFLATE (ZIP-compatible). Level 1 = MZ_BEST_SPEED.
 * Returns malloc'd compressed buffer (free with bkp_free). NULL on failure.
 * *out_len = compressed size; *crc_out = CRC-32 of uncompressed data.
 */
unsigned char *bkp_deflate(const unsigned char *src, size_t src_len,
                           size_t *out_len, unsigned int *crc_out)
{
	mz_uint flags;
	void   *out;

	if (!out_len || !crc_out)
		return NULL;

	*out_len  = 0;
	*crc_out  = (unsigned int)mz_crc32(MZ_CRC32_INIT, src, src_len);

	/* Empty payload: still a valid empty deflate stream is fine; use store path upstream if preferred. */
	flags = tdefl_create_comp_flags_from_zip_params(
		MZ_BEST_SPEED, -MZ_DEFAULT_WINDOW_BITS, MZ_DEFAULT_STRATEGY);

	out = tdefl_compress_mem_to_heap(src, src_len, out_len, (int)flags);
	return (unsigned char *)out;
}

void bkp_free(void *p)
{
	if (p)
		mz_free(p);
}

Bkp_Zip *bkp_zip_open(const char *path)
{
	Bkp_Zip *z;

	if (!path)
		return NULL;
	z = (Bkp_Zip *)calloc(1, sizeof(Bkp_Zip));
	if (!z)
		return NULL;
	mz_zip_zero_struct(&z->zip);
	if (!mz_zip_writer_init_file(&z->zip, path, 0)) {
		free(z);
		return NULL;
	}
	return z;
}

/* Add already-compressed (raw DEFLATE) data as a ZIP entry. */
int bkp_zip_add_precompressed(Bkp_Zip *z, const char *name,
                              const void *comp, size_t comp_len,
                              size_t uncomp_len, unsigned int crc)
{
	if (!z || !name)
		return 0;
	return mz_zip_writer_add_mem_ex(
		       &z->zip, name, comp, comp_len, NULL, 0,
		       (mz_uint)(MZ_ZIP_FLAG_COMPRESSED_DATA | MZ_BEST_SPEED),
		       (mz_uint64)uncomp_len, crc)
	           ? 1
	           : 0;
}

/* Add uncompressed (stored) entry — used when deflate does not shrink. */
int bkp_zip_add_stored(Bkp_Zip *z, const char *name, const void *buf, size_t len,
                       unsigned int crc)
{
	if (!z || !name)
		return 0;
	(void)crc; /* miniz recomputes CRC for level-0 / stored path */
	return mz_zip_writer_add_mem(&z->zip, name, buf, len, (mz_uint)MZ_NO_COMPRESSION) ? 1 : 0;
}

/* Directory entry: name should end with '/'. */
int bkp_zip_add_dir(Bkp_Zip *z, const char *name)
{
	if (!z || !name)
		return 0;
	return mz_zip_writer_add_mem(&z->zip, name, NULL, 0, (mz_uint)MZ_NO_COMPRESSION) ? 1 : 0;
}

int bkp_zip_close(Bkp_Zip *z)
{
	int ok;

	if (!z)
		return 0;
	ok = 1;
	if (!z->finalized) {
		if (!mz_zip_writer_finalize_archive(&z->zip))
			ok = 0;
		z->finalized = 1;
	}
	if (!mz_zip_writer_end(&z->zip))
		ok = 0;
	free(z);
	return ok;
}

/* Abort without requiring a valid finalize (delete partial archive outside). */
void bkp_zip_abort(Bkp_Zip *z)
{
	if (!z)
		return;
	/* End without finalize — archive will be incomplete; caller removes file. */
	mz_zip_writer_end(&z->zip);
	free(z);
}
