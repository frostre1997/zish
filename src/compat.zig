//! Zig 0.16 compatibility layer.
//!
//! 0.16 moved file/dir APIs behind an explicit `std.Io` parameter and removed
//! most process-level functions from `std.posix`. zish is a synchronous,
//! linux-only program that does raw fd work for job control, so:
//!
//! - `compat.io()` exposes one global `std.Io` for the whole process,
//!   wired from `std.process.Init` in main (lazy `Io.Threaded` fallback
//!   for tests).
//! - `compat.posix` re-exports what survives in `std.posix` and lifts the
//!   removed functions from the 0.15.2 stdlib (libc-backed, linux paths only),
//!   keeping the old error-union signatures so call sites stay unchanged.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

// ---------------------------------------------------------------------------
// Global Io
// ---------------------------------------------------------------------------

var io_instance: std.Io = undefined;
var io_initialized = false;
var threaded_fallback: std.Io.Threaded = undefined;

/// Called once from main() with std.process.Init.io before anything else runs.
pub fn setIo(io_: std.Io) void {
    io_instance = io_;
    io_initialized = true;
}

/// Global Io accessor. Lazy Threaded fallback covers unit tests and any
/// code path that runs before main wires up Init.io. Not thread-safe on
/// first call — main calls setIo before threads spawn.
pub fn io() std.Io {
    if (!io_initialized) {
        threaded_fallback = std.Io.Threaded.init(std.heap.page_allocator, .{});
        io_instance = threaded_fallback.io();
        io_initialized = true;
    }
    return io_instance;
}

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

fn nowNs(clock: std.Io.Clock) i96 {
    return std.Io.Clock.now(clock, io()).nanoseconds;
}

pub fn timestamp() i64 {
    return @intCast(@divFloor(nowNs(.real), std.time.ns_per_s));
}

pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(nowNs(.real), std.time.ns_per_ms));
}

pub fn nanoTimestamp() i128 {
    return @intCast(nowNs(.real));
}

pub fn sleep(ns: u64) void {
    const dur: std.Io.Clock.Duration = .{
        .raw = .fromNanoseconds(@intCast(ns)),
        .clock = .awake,
    };
    dur.sleep(io()) catch {};
}

// ---------------------------------------------------------------------------
// File I/O replacements
// ---------------------------------------------------------------------------

pub fn readAll(file: std.Io.File, buf: []u8) !usize {
    var n: usize = 0;
    while (n < buf.len) {
        const r = try file.readStreaming(io(), &.{buf[n..]});
        if (r == 0) break;
        n += r;
    }
    return n;
}

pub fn writeAll(file: std.Io.File, bytes: []const u8) !void {
    return file.writeStreamingAll(io(), bytes);
}

// ---------------------------------------------------------------------------
// Env access
// ---------------------------------------------------------------------------

pub const GetEnvVarOwnedError = error{ OutOfMemory, EnvironmentVariableNotFound, InvalidWtf8 };

pub fn getEnvVarOwned(allocator: mem.Allocator, key: []const u8) GetEnvVarOwnedError![]u8 {
    const v = posix.getenv(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, v);
}

// ---------------------------------------------------------------------------
// posix compatibility namespace
// ---------------------------------------------------------------------------

pub const posix = struct {
    const system = std.c;

    // --- Bionic libc direct bindings (avoids std.c/std.posix stripping) ---
    const libc = struct {
        extern "c" fn exit(status: c_int) noreturn;
        extern "c" fn getpgid(pid: pid_t) pid_t;
        extern "c" fn getegid() c_uint;
        extern "c" fn geteuid() c_uint;
        extern "c" fn fork() pid_t;
        extern "c" fn waitpid(pid: pid_t, status: *c_int, options: c_int) pid_t;
        extern "c" fn lseek64(fd: fd_t, offset: i64, whence: c_int) i64;
        extern "c" fn lstat(path: [*:0]const u8, buf: *std.c.Stat) c_int;
        extern "c" fn stat(path: [*:0]const u8, buf: *std.c.Stat) c_int;
    };

    // --- re-exports still present in 0.16 std.posix ---
    pub const fd_t = std.posix.fd_t;
    pub const pid_t = std.posix.pid_t;
    pub const mode_t = std.posix.mode_t;
    pub const O = std.posix.O;
    pub const SIG = std.posix.SIG;
    pub const W = std.posix.W;
    pub const POLL = std.posix.POLL;
    pub const pollfd = std.posix.pollfd;
    pub const poll = std.posix.poll;
    pub const sigset_t = std.posix.sigset_t;
    pub const Sigaction = std.posix.Sigaction;
    pub const sigaction = std.posix.sigaction;
    pub const sigprocmask = std.posix.sigprocmask;
    pub const sigemptyset = std.posix.sigemptyset;
    pub const termios = std.posix.termios;
    pub const tcgetattr = std.posix.tcgetattr;
    pub const tcsetattr = std.posix.tcsetattr;
    pub const tcgetpgrp = std.posix.tcgetpgrp;
    pub const tcsetpgrp = std.posix.tcsetpgrp;
    pub const TermioSetPgrpError = std.posix.TermioSetPgrpError;
    pub const T = std.posix.T;
    pub const V = std.posix.V;
    pub const winsize = std.posix.winsize;
    pub const timeval = std.posix.timeval;
    pub const STDIN_FILENO = std.posix.STDIN_FILENO;
    pub const STDOUT_FILENO = std.posix.STDOUT_FILENO;
    pub const STDERR_FILENO = std.posix.STDERR_FILENO;
    pub const PATH_MAX = std.posix.PATH_MAX;
    pub const HOST_NAME_MAX = std.posix.HOST_NAME_MAX;
    pub const gethostname = std.posix.gethostname;
    pub const kill = std.posix.kill;
    pub const read = std.posix.read;
    pub const errno = std.posix.errno;
    pub const unexpectedErrno = std.posix.unexpectedErrno;
    pub const E = std.posix.E;
    pub const Stat = if (builtin.os.tag == .linux) std.os.linux.Statx else std.c.Stat;
    pub const ReadError = std.posix.ReadError;

    // --- lifted implementations ---

    pub fn exit(status: u8) noreturn {
        libc.exit(status);
    }

    pub const ForkError = error{ SystemResources, Unexpected };

    pub fn fork() ForkError!pid_t {
        const rc = libc.fork();
        if (rc < 0) {
            switch (errno(rc)) {
                .AGAIN => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                else => |err| return unexpectedErrno(err),
            }
        }
        return rc;
    }

    pub const WaitPidResult = struct {
        pid: pid_t,
        status: u32,
    };

    pub fn waitpid(pid: pid_t, flags: u32) WaitPidResult {
        var status: c_int = 0;
        const rc = libc.waitpid(pid, &status, @intCast(flags));
        return .{ .pid = rc, .status = @bitCast(status) };
    }

    pub fn getProcessGroup(pid: pid_t) pid_t {
        return libc.getpgid(pid);
    }

    pub fn getegid() u32 {
        return @intCast(libc.getegid());
    }

    pub fn geteuid() u32 {
        return @intCast(libc.geteuid());
    }

    pub const GetCwdError = error{ NameTooLong, AccessDenied, Unexpected };

    pub fn getcwd(buf: []u8) GetCwdError![]u8 {
        if (builtin.os.tag == .linux) {
            const rc = std.os.linux.getcwd(buf.ptr, buf.len);
            const signed_rc: isize = @bitCast(rc);
            if (signed_rc >= 0) return buf[0..@intCast(signed_rc)];
            switch (std.posix.errno(signed_rc)) {
                .RANGE => return error.NameTooLong,
                .ACCES => return error.AccessDenied,
                else => |err| return unexpectedErrno(err),
            }
        } else {
            const rc = system.getcwd(buf.ptr, buf.len);
            if (rc != null) return mem.sliceTo(buf, 0);
            switch (errno(-1)) {
                .RANGE => return error.NameTooLong,
                .ACCES => return error.AccessDenied,
                else => |err| return unexpectedErrno(err),
            }
        }
    }

    pub fn getenv(key: []const u8) ?[:0]const u8 {
        if (mem.indexOfScalar(u8, key, '=') != null) return null;
        var ptr = std.c.environ;
        while (ptr[0]) |line| : (ptr += 1) {
            var line_i: usize = 0;
            while (line[line_i] != 0) : (line_i += 1) {
                if (line_i == key.len) break;
                if (line[line_i] != key[line_i]) break;
            }
            if ((line_i != key.len) or (line[line_i] != '=')) continue;
            return mem.sliceTo(line + line_i + 1, 0);
        }
        return null;
    }

    pub fn getenvZ(key: [*:0]const u8) ?[:0]const u8 {
        const value = system.getenv(key) orelse return null;
        return mem.sliceTo(value, 0);
    }

    pub fn close(fd: fd_t) void {
        switch (errno(system.close(fd))) {
            .BADF => unreachable,
            .INTR => return,
            else => return,
        }
    }

    pub fn chdir(path: []const u8) !void {
        const path_c = toPosixPath(path) catch return error.NameTooLong;
        switch (errno(system.chdir(&path_c))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NAMETOOLONG => return error.NameTooLong,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub fn lseek(fd: fd_t, offset: i64, whence: u32) !i64 {
        if (builtin.os.tag == .linux) {
            if (builtin.target.abi.isAndroid() and builtin.target.ptrBitWidth() == 32) {
                const rc = libc.lseek64(fd, offset, @intCast(whence));
                if (rc < 0) return error.SeekFailed;
                return rc;
            }
            const rc = std.os.linux.lseek(fd, offset, whence);
            if (@as(isize, @bitCast(rc)) < 0) return error.SeekFailed;
            return @intCast(rc);
        } else {
            const rc = std.c.lseek(fd, @intCast(offset), @enumFromInt(whence));
            if (rc < 0) return error.SeekFailed;
            return @intCast(rc);
        }
    }

    pub fn dup2(old_fd: fd_t, new_fd: fd_t) !void {
        while (true) {
            switch (errno(system.dup2(old_fd, new_fd))) {
                .SUCCESS => return,
                .BUSY, .INTR => continue,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .INVAL, .BADF => return error.BadFileDescriptor,
                else => |err| return unexpectedErrno(err),
            }
        }
    }

    pub const WriteError = error{
        DiskQuota, FileTooBig, InputOutput, NoSpaceLeft, DeviceBusy,
        InvalidArgument, AccessDenied, PermissionDenied, BrokenPipe,
        SystemResources, OperationAborted, NotOpenForWriting, LockViolation,
        WouldBlock, ConnectionResetByPeer, ProcessNotFound, NoDevice,
        MessageTooBig, Unexpected,
    };

    pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
        if (bytes.len == 0) return 0;
        while (true) {
            const rc = system.write(fd, bytes.ptr, @min(bytes.len, std.math.maxInt(isize)));
            switch (errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .INVAL => return error.InvalidArgument,
                .FAULT => unreachable,
                .AGAIN => return error.WouldBlock,
                .BADF => return error.NotOpenForWriting,
                .DESTADDRREQ => unreachable,
                .DQUOT => return error.DiskQuota,
                .FBIG => return error.FileTooBig,
                .IO => return error.InputOutput,
                .NOSPC => return error.NoSpaceLeft,
                .ACCES => return error.AccessDenied,
                .PERM => return error.PermissionDenied,
                .PIPE => return error.BrokenPipe,
                .NXIO => return error.NoDevice,
                .NODEV => return error.NoDevice,
                .SRCH => return error.ProcessNotFound,
                .CONNRESET => return error.ConnectionResetByPeer,
                .BUSY => return error.DeviceBusy,
                else => |err| return unexpectedErrno(err),
            }
        }
    }

    pub const OpenError = error{
        AccessDenied, PermissionDenied, FileTooBig, IsDir, SymLinkLoop,
        ProcessFdQuotaExceeded, NameTooLong, SystemFdQuotaExceeded, NoDevice,
        FileNotFound, ProcessNotFound, SystemResources, NoSpaceLeft, NotDir,
        PathAlreadyExists, DeviceBusy, BadPathName, Unexpected,
    };

    pub fn open(file_path: []const u8, flags: O, perm: mode_t) OpenError!fd_t {
        const file_path_c = toPosixPath(file_path) catch return error.NameTooLong;
        return openZ(&file_path_c, flags, perm);
    }

    pub fn openZ(file_path: [*:0]const u8, flags: O, perm: mode_t) OpenError!fd_t {
        while (true) {
            const rc = system.open(file_path, flags, perm);
            switch (errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .FAULT => unreachable,
                .INVAL => return error.BadPathName,
                .ACCES => return error.AccessDenied,
                .FBIG => return error.FileTooBig,
                .OVERFLOW => return error.FileTooBig,
                .ISDIR => return error.IsDir,
                .LOOP => return error.SymLinkLoop,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NAMETOOLONG => return error.NameTooLong,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NXIO => return error.NoDevice,
                .NODEV => return error.NoDevice,
                .NOENT => return error.FileNotFound,
                .SRCH => return error.ProcessNotFound,
                .NOMEM => return error.SystemResources,
                .NOSPC => return error.NoSpaceLeft,
                .NOTDIR => return error.NotDir,
                .PERM => return error.PermissionDenied,
                .EXIST => return error.PathAlreadyExists,
                .BUSY => return error.DeviceBusy,
                else => |err| return unexpectedErrno(err),
            }
        }
    }

    pub const PipeError = error{ SystemFdQuotaExceeded, ProcessFdQuotaExceeded, Unexpected };

    pub fn pipe() PipeError![2]fd_t {
        var fds: [2]fd_t = undefined;
        switch (errno(system.pipe(&fds))) {
            .SUCCESS => return fds,
            .INVAL => unreachable,
            .FAULT => unreachable,
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub const FcntlError = error{
        Locked, FileBusy, PermissionDenied, ProcessFdQuotaExceeded,
        DeadLock, LockedRegionLimitExceeded, Unexpected,
    };

    pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) FcntlError!usize {
        while (true) {
            const rc = system.fcntl(fd, cmd, arg);
            switch (errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN, .ACCES => return error.Locked,
                .BADF => unreachable,
                .BUSY => return error.FileBusy,
                .INVAL => unreachable,
                .PERM => return error.PermissionDenied,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NOTDIR => unreachable,
                .DEADLK => return error.DeadLock,
                .NOLCK => return error.LockedRegionLimitExceeded,
                else => |err| return unexpectedErrno(err),
            }
        }
    }

    pub fn dupHighCloexec(fd: fd_t) FcntlError!fd_t {
        const F_DUPFD_CLOEXEC = 1030;
        return @intCast(try fcntl(fd, F_DUPFD_CLOEXEC, 10));
    }

    pub const FStatError = error{ SystemResources, AccessDenied, BadFileDescriptor, Unexpected };

    pub fn fstat(fd: fd_t) FStatError!Stat {
        var stat = mem.zeroes(Stat);
        if (builtin.os.tag != .linux) {
            switch (std.posix.errno(std.c.fstat(fd, &stat))) {
                .SUCCESS => return stat,
                .BADF => return error.BadFileDescriptor,
                .NOMEM => return error.SystemResources,
                .ACCES => return error.AccessDenied,
                else => |err| return unexpectedErrno(err),
            }
        }
        const linux = std.os.linux;
        switch (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stat))) {
            .SUCCESS => return stat,
            .INVAL => unreachable,
            .BADF => return error.BadFileDescriptor,
            .NOMEM => return error.SystemResources,
            .ACCES => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub fn isatty(handle: fd_t) bool {
        return system.isatty(handle) != 0;
    }

    pub const FileStat = struct {
        dev: u64, ino: u64, uid: u32, gid: u32, mode: u32, mtime_ns: i128,
    };

    pub fn statPath(pathz: [*:0]const u8, follow: bool) ?FileStat {
        if (builtin.os.tag == .linux) {
            const linux = std.os.linux;
            var st: linux.Statx = undefined;
            const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true, .GID = true, .INO = true, .MTIME = true };
            const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
            if (linux.statx(linux.AT.FDCWD, pathz, flags, mask, &st) != 0) return null;
            return .{
                .dev = (@as(u64, st.dev_major) << 32) | @as(u64, st.dev_minor),
                .ino = st.ino, .uid = st.uid, .gid = st.gid, .mode = st.mode,
                .mtime_ns = @as(i128, st.mtime.sec) * std.time.ns_per_s + @as(i128, st.mtime.nsec),
            };
        }
        var cst: std.c.Stat = undefined;
        const rc = if (follow) libc.stat(pathz, &cst) else libc.lstat(pathz, &cst);
        if (rc != 0) return null;
        const st = cst;
        const ts = st.mtime();
        return .{
            .dev = @intCast(@as(i64, st.dev)), .ino = @intCast(st.ino), .uid = st.uid,
            .gid = st.gid, .mode = st.mode,
            .mtime_ns = @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec),
        };
    }

    pub fn getpid() pid_t { return system.getpid(); }

    pub fn randomBytes(buf: []u8) void {
        if (builtin.os.tag == .linux) {
            var off: usize = 0;
            while (off < buf.len) {
                const rc = std.os.linux.getrandom(buf[off..].ptr, buf.len - off, 0);
                const n: isize = @bitCast(rc);
                if (n <= 0) return;
                off += @intCast(n);
            }
        } else {
            std.crypto.random.bytes(buf);
        }
    }

    pub const SetPgidError = error{
        ProcessAlreadyExec, InvalidProcessGroupId, PermissionDenied, ProcessNotFound, Unexpected,
    };

    pub fn setpgid(pid: pid_t, pgid: pid_t) SetPgidError!void {
        switch (errno(system.setpgid(pid, pgid))) {
            .SUCCESS => return,
            .ACCES => return error.ProcessAlreadyExec,
            .INVAL => return error.InvalidProcessGroupId,
            .PERM => return error.PermissionDenied,
            .SRCH => return error.ProcessNotFound,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub const ExecveError = error{
        SystemResources, AccessDenied, PermissionDenied, InvalidExe,
        FileSystem, IsDir, FileNotFound, NotDir, FileBusy,
        ProcessFdQuotaExceeded, SystemFdQuotaExceeded, NameTooLong, Unexpected,
    };

    pub fn execveZ(
        path: [*:0]const u8,
        child_argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) ExecveError {
        switch (errno(system.execve(path, child_argv, envp))) {
            .SUCCESS => unreachable,
            .FAULT => unreachable,
            .@"2BIG" => return error.SystemResources,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .INVAL => return error.InvalidExe,
            .NOEXEC => return error.InvalidExe,
            .IO => return error.FileSystem,
            .LOOP => return error.FileSystem,
            .ISDIR => return error.IsDir,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .TXTBSY => return error.FileBusy,
            else => |err| {
                const ErrT = @TypeOf(err);
                if (comptime @hasField(ErrT, "LIBBAD")) {
                    if (err == @field(ErrT, "LIBBAD")) return error.InvalidExe;
                }
                return unexpectedErrno(err);
            },
        }
    }

    pub fn execvpeZ(
        file: [*:0]const u8,
        argv_ptr: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) ExecveError {
        const file_slice = mem.sliceTo(file, 0);
        if (mem.indexOfScalar(u8, file_slice, '/') != null) return execveZ(file, argv_ptr, envp);

        const PATH = getenvZ("PATH") orelse "/usr/local/bin:/bin/:/usr/bin";
        var path_buf: [PATH_MAX]u8 = undefined;
        var it = mem.tokenizeScalar(u8, PATH, ':');
        var seen_eacces = false;
        var err: ExecveError = error.FileNotFound;

        while (it.next()) |search_path| {
            const path_len = search_path.len + file_slice.len + 1;
            if (path_buf.len < path_len + 1) return error.NameTooLong;
            @memcpy(path_buf[0..search_path.len], search_path);
            path_buf[search_path.len] = '/';
            @memcpy(path_buf[search_path.len + 1 ..][0..file_slice.len], file_slice);
            path_buf[path_len] = 0;
            const full_path = path_buf[0..path_len :0].ptr;
            err = execveZ(full_path, argv_ptr, envp);
            switch (err) {
                error.AccessDenied => seen_eacces = true,
                error.FileNotFound, error.NotDir => {},
                else => |e| return e,
            }
        }
        if (seen_eacces) return error.AccessDenied;
        return err;
    }

    pub fn toPosixPath(file_path: []const u8) error{NameTooLong}![PATH_MAX - 1:0]u8 {
        var path_with_null: [PATH_MAX - 1:0]u8 = undefined;
        if (file_path.len >= PATH_MAX) return error.NameTooLong;
        @memcpy(path_with_null[0..file_path.len], file_path);
        path_with_null[file_path.len] = 0;
        return path_with_null;
    }
};

test "compat getenv finds PATH" {
    try std.testing.expect(posix.getenv("PATH") != null);
    try std.testing.expect(posix.getenv("ZISH_DEFINITELY_NOT_SET_12345") == null);
}

test "compat getcwd works" {
    var buf: [4096]u8 = undefined;
    const cwd = try posix.getcwd(&buf);
    try std.testing.expect(cwd.len > 0);
}
