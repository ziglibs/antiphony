const std = @import("std");
const rpc = @import("rpc");

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

fn spawnHost() void {
    var listener = undefined;

    var socket = try listener.accept();

    const HostImpl = struct {
        const Self = @This();

        counters: std.ArrayList(u32),

        fn createCounter(self: *Self) CreateError!u32 {
            // TODO: Implement these
        }
        fn destroyCounter(self: *Self, u32) void {
            // TODO: Implement these
        }
        fn increment(self: *Self, u32, u32) UsageError!u32 {
            // TODO: Implement these
        }
        fn getCount(self: *Self, u32) UsageError!u32 {
            // TODO: Implement these
        }
    };

    var impl = HostImpl{
        .counters = std.ArrayList(u32).init(allocator),
    };
    defer impl.counters.deinit();

    const HostBinder = RcpDefinition.HostBinder(Reader, Writer, HostImpl);

    var binder = HostBinder.create(
        allocator, // we need some basic session management
        socket.reader(), // data input
        socket.writer(), // data output
    );
    defer binder.destroy();

    try binder.connect(&impl); // establish RPC handshake

    try binder.acceptCalls(); // blocks until client exits.
}

fn connectClient() void {
    var socket = connect();
    defer socket.close();

    const ClientImpl = struct {
        fn signalError(self: @This(), msg: []const u8) void {
            _ = self;
            std.log.err("remote error: {s}", .{msg});
        }
    };

    var binder = RcpDefinition.createBinder(
        .client,
        allocator,
        socket.reader(),
        socket.writer(),
        ClientImpl,
    );
    defer binder.destroy();

    var impl = ClientImpl{};
    try binder.connect(&impl); // establish RPC handshake

    const handle = try binder.invoke("createCounter", .{});

    std.log.info("first increment:  {}", .{try binder.invoke("increment", .{5})});
    std.log.info("second increment: {}", .{try binder.invoke("increment", .{3})});
    std.log.info("third increment:  {}", .{try binder.invoke("increment", .{7})});
    std.log.info("final count:      {}", .{try binder.invoke("getCount", .{})});

    try binder.invoke("destroyCounter", .{handle});
}
