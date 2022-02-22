const std = @import("std");
const rpc = @import("antiphony");

const CreateError = error{ OutOfMemory, UnknownCounter };
const UsageError = error{ OutOfMemory, UnknownCounter };

const RcpDefinition = rpc.CreateDefinition(.{
    .host = .{
        .createCounter = fn () CreateError!u32,
        .destroyCounter = fn (u32) void,
        .increment = fn (u32, u32) UsageError!u32,
        .getCount = fn (u32) UsageError!u32,
    },
    .client = .{
        .signalError = fn (msg: []const u8) void,
    },
});

pub fn main() !void {
    var sockets: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &sockets) != 0)
        return error.SocketPairError;

    var socket_a = std.fs.File{ .handle = sockets[0] };
    defer socket_a.close();

    var socket_b = std.fs.File{ .handle = sockets[1] };
    defer socket_b.close();

    {
        var client_thread = try std.Thread.spawn(.{}, clientImplementation, .{socket_a});
        defer client_thread.join();

        var host_thread = try std.Thread.spawn(.{}, hostImplementation, .{socket_b});
        defer host_thread.join();
    }
}

fn clientImplementation(file: std.fs.File) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const ClientImpl = struct {
        pub fn signalError(msg: []const u8) void {
            std.log.err("remote error: {s}", .{msg});
        }
    };

    const Binder = RcpDefinition.ClientBinder(std.fs.File.Reader, std.fs.File.Writer, ClientImpl);

    var binder = Binder.init(
        gpa.allocator(),
        file.reader(),
        file.writer(),
    );
    defer binder.destroy();

    var impl = ClientImpl{};
    try binder.connect(&impl); // establish RPC handshake

    const handle = try try binder.invoke("createCounter", .{});

    std.log.info("first increment:  {}", .{try binder.invoke("increment", .{ handle, 5 })});
    std.log.info("second increment: {}", .{try binder.invoke("increment", .{ handle, 3 })});
    std.log.info("third increment:  {}", .{try binder.invoke("increment", .{ handle, 7 })});
    std.log.info("final count:      {}", .{try binder.invoke("getCount", .{handle})});

    try binder.invoke("destroyCounter", .{handle});
}

fn hostImplementation(file: std.fs.File) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const HostImpl = struct {
        const Self = @This();

        counters: std.ArrayList(?u32),

        pub fn createCounter(self: *Self) CreateError!u32 {
            const index = @truncate(u32, self.counters.items.len);
            try self.counters.append(0);
            return index;
        }
        pub fn destroyCounter(self: *Self, handle: u32) void {
            if (handle >= self.counters.items.len)
                return;
            self.counters.items[handle] = null;
        }
        pub fn increment(self: *Self, handle: u32, count: u32) UsageError!u32 {
            if (handle >= self.counters.items.len)
                return error.UnknownCounter;
            if (self.counters.items[handle]) |*counter| {
                const previous = counter.*;
                counter.* +%= count;
                return previous;
            } else {
                return error.UnknownCounter;
            }
        }
        pub fn getCount(self: *Self, handle: u32) UsageError!u32 {
            if (handle >= self.counters.items.len)
                return error.UnknownCounter;
            if (self.counters.items[handle]) |value| {
                return value;
            } else {
                return error.UnknownCounter;
            }
        }
    };

    var impl = HostImpl{
        .counters = std.ArrayList(?u32).init(gpa.allocator()),
    };
    defer impl.counters.deinit();

    const HostBinder = RcpDefinition.HostBinder(std.fs.File.Reader, std.fs.File.Writer, HostImpl);

    var binder = HostBinder.init(
        gpa.allocator(), // we need some basic session management
        file.reader(), // data input
        file.writer(), // data output
    );
    defer binder.destroy();

    try binder.connect(&impl); // establish RPC handshake

    try binder.acceptCalls(); // blocks until client exits.
}
