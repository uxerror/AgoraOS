class_name AgoraErrno
extends RefCounted
## Unix-style error codes shared by the whole kernel.

const OK := 0
const EPERM := 1
const ENOENT := 2
const ESRCH := 3
const EIO := 5
const ENOEXEC := 8
const EBADF := 9
const EACCES := 13
const EBUSY := 16
const EEXIST := 17
const EXDEV := 18
const ENOTDIR := 20
const EISDIR := 21
const EINVAL := 22
const EROFS := 30
const EPIPE := 32
const ENAMETOOLONG := 36
const ENOTEMPTY := 39
const ELOOP := 40
const EADDRINUSE := 98
const ECONNREFUSED := 111
const EHOSTUNREACH := 113

const _TEXT := {
	OK: "Success",
	EPERM: "Operation not permitted",
	ENOENT: "No such file or directory",
	ESRCH: "No such process",
	EIO: "Input/output error",
	ENOEXEC: "Exec format error",
	EBADF: "Bad file descriptor",
	EACCES: "Permission denied",
	EBUSY: "Device or resource busy",
	EEXIST: "File exists",
	EXDEV: "Invalid cross-device link",
	ENOTDIR: "Not a directory",
	EISDIR: "Is a directory",
	EINVAL: "Invalid argument",
	EROFS: "Read-only file system",
	EPIPE: "Broken pipe",
	ENAMETOOLONG: "File name too long",
	ENOTEMPTY: "Directory not empty",
	ELOOP: "Too many levels of symbolic links",
	EADDRINUSE: "Address already in use",
	ECONNREFUSED: "Connection refused",
	EHOSTUNREACH: "No route to host",
}


static func describe(code: int) -> String:
	return _TEXT.get(code, "Unknown error %d" % code)
