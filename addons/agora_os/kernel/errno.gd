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
const ENODEV := 19
const ENOTDIR := 20
const EISDIR := 21
const EINVAL := 22
const EROFS := 30
const EPIPE := 32
const ENAMETOOLONG := 36
const ENOTEMPTY := 39
const ELOOP := 40
const EMSGSIZE := 90
const ENOPROTOOPT := 92
const EOPNOTSUPP := 95
const EADDRINUSE := 98
const EADDRNOTAVAIL := 99
const ENETDOWN := 100
const ENETUNREACH := 101
const ECONNRESET := 104
const ETIMEDOUT := 110
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
	ENODEV: "No such device",
	ENOTDIR: "Not a directory",
	EISDIR: "Is a directory",
	EINVAL: "Invalid argument",
	EROFS: "Read-only file system",
	EPIPE: "Broken pipe",
	ENAMETOOLONG: "File name too long",
	ENOTEMPTY: "Directory not empty",
	ELOOP: "Too many levels of symbolic links",
	EMSGSIZE: "Message too long",
	ENOPROTOOPT: "Protocol not available",
	EOPNOTSUPP: "Operation not supported",
	EADDRINUSE: "Address already in use",
	EADDRNOTAVAIL: "Cannot assign requested address",
	ENETDOWN: "Network is down",
	ENETUNREACH: "Network is unreachable",
	ECONNRESET: "Connection reset by peer",
	ETIMEDOUT: "Connection timed out",
	ECONNREFUSED: "Connection refused",
	EHOSTUNREACH: "No route to host",
}


static func describe(code: int) -> String:
	return _TEXT.get(code, "Unknown error %d" % code)
