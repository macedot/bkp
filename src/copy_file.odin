package main

import "core:os"

// copy_file_preserve copies a regular file to dst, preserving mode when possible.
// Fails if dst already exists.
copy_file_preserve :: proc(dst, src: string) -> (err: os.Error) {
	if os.exists(dst) {
		return os.General_Error.Exist
	}

	info: os.File_Info
	info, err = os.stat(src, context.allocator)
	if err != nil {
		return err
	}
	defer os.file_info_delete(info, context.allocator)

	if info.type == .Directory {
		return os.General_Error.Invalid_Dir
	}
	if info.type != .Regular && info.type != .Symlink && info.type != .Undetermined {
		return os.General_Error.Invalid_File
	}

	if err = os.copy_file(dst, src); err != nil {
		return err
	}

	// Best-effort mode preserve (like cp -p mode bits).
	_ = os.chmod(dst, info.mode)
	return nil
}
