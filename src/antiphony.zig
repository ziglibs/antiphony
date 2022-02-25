const std = @import("std");
const s2s = @import("s2s");
const logger = std.log.scoped(.antiphony_rpc);

/// The role of an EndPoint. `host` and `client` are arbitrary names that define both ends.
/// The `host` role usually calls `EndPoint.acceptCalls()` and waits for incoming calls.
pub const Role = enum { host, client };

pub const Config = struct {
    /// If this is set, a call to `EndPoint.invoke()` will merge the remote error set into
    /// the error set of `invoke()` itself, so a single `try invoke()` will suffice.
    /// Otherwise, the return type will be`InvokeError!InvocationResult(RemoteResult)`.
    merge_error_sets: bool = true,
};

/// Returns a wrapper struct that contains the result of a function invocation.
/// This is needed as s2s cannot serialize raw top level errors.
pub fn InvocationResult(comptime T: type) type {
    return struct {
        value: T,

        fn unwrap(self: @This()) T {
            return self.value;
        }
    };
}

/// Create a new RPC definition that can be used to instantiate end points.
pub fn CreateDefinition(comptime spec: anytype) type {
    const host_spec = spec.host;
    const client_spec = spec.client;
    const config: Config = if (@hasField(@TypeOf(spec), "config"))
        spec.config
    else
        Config{};

    comptime validateSpec(host_spec);
    comptime validateSpec(client_spec);

    return struct {
        const Self = @This();

        pub fn HostEndPoint(comptime Reader: type, comptime Writer: type, comptime Implementation: type) type {
            return CreateEndPoint(.host, Reader, Writer, Implementation);
        }

        pub fn ClientEndPoint(comptime Reader: type, comptime Writer: type, comptime Implementation: type) type {
            return CreateEndPoint(.client, Reader, Writer, Implementation);
        }

        pub fn CreateEndPoint(comptime role: Role, comptime ReaderType: type, comptime WriterType: type, comptime ImplementationType: type) type {
            const inbound_spec = switch (role) {
                .host => host_spec,
                .client => client_spec,
            };
            const outbound_spec = switch (role) {
                .host => client_spec,
                .client => host_spec,
            };
            const InboundSpec = @TypeOf(inbound_spec);

            const max_received_func_name_len = comptime blk: {
                var len = 0;
                for (std.meta.fields(InboundSpec)) |fld| {
                    len = std.math.max(fld.name.len, len);
                }
                break :blk len;
            };

            return struct {
                const EndPoint = @This();
                pub const Reader = ReaderType;
                pub const Writer = WriterType;
                pub const Implementation = ImplementationType;

                pub const IoError = Reader.Error || Writer.Error || error{EndOfStream};
                pub const ProtocolError = error{ ProtocolViolation, InvalidProtocol, ProtocolMismatch };
                pub const InvokeError = IoError || ProtocolError || std.mem.Allocator.Error;
                pub const ConnectError = IoError || ProtocolError;

                allocator: std.mem.Allocator,
                reader: Reader,
                writer: Writer,

                sequence_id: u32 = 0,
                impl: ?*Implementation = null,

                pub fn init(allocator: std.mem.Allocator, reader: Reader, writer: Writer) EndPoint {
                    return EndPoint{
                        .allocator = allocator,
                        .reader = reader,
                        .writer = writer,
                    };
                }
                pub fn destroy(self: *EndPoint) void {
                    // // make sure the other connection is gracefully shut down in any case
                    // if (self.impl != null) {
                    //     self.shutdown() catch |err| logger.warn("failed to shut down remote connection gracefully: {s}", .{@errorName(err)});
                    // }
                    self.* = undefined;
                }

                /// Performs the initial handshake with the remote peer.
                /// Both agree on the used RPC version and that they use the same protocol.
                pub fn connect(self: *EndPoint, impl: *Implementation) ConnectError!void {
                    std.debug.assert(self.impl == null); // do not call twice

                    try self.writer.writeAll(&protocol_magic);
                    try self.writer.writeByte(current_version); // version byte

                    var remote_magic: [4]u8 = undefined;
                    try self.reader.readNoEof(&remote_magic);
                    if (!std.mem.eql(u8, &protocol_magic, &remote_magic))
                        return error.InvalidProtocol;

                    const remote_version = try self.reader.readByte();
                    if (remote_version != current_version)
                        return error.ProtocolMismatch;

                    self.impl = impl;
                }

                /// Shuts down the connection and exits the loop inside `acceptCalls()` on the remote peer.
                ///
                /// Must be called only after a successful call to `connect()`.
                pub fn shutdown(self: *EndPoint) IoError!void {
                    std.debug.assert(self.impl != null); // call these only after a successful connection!
                    try self.writer.writeByte(@enumToInt(CommandId.shutdown));
                }

                /// Waits for incoming calls and handles them till the client shuts down the connection.
                ///
                /// Must be called only after a successful call to `connect()`.
                pub fn acceptCalls(self: *EndPoint) InvokeError!void {
                    std.debug.assert(self.impl != null); // call these only after a successful connection!
                    while (true) {
                        const cmd_id = try self.reader.readByte();
                        const cmd = std.meta.intToEnum(CommandId, cmd_id) catch return error.ProtocolViolation;
                        switch (cmd) {
                            .call => {
                                try self.processCall();
                            },
                            .response => return error.ProtocolViolation,
                            .shutdown => return,
                        }
                    }
                }

                fn InvokeReturnType(comptime func_name: []const u8) type {
                    const FuncPrototype = @field(outbound_spec, func_name);
                    const func_info = @typeInfo(FuncPrototype).Fn;
                    const FuncReturnType = func_info.return_type.?;

                    if (config.merge_error_sets) {
                        switch (@typeInfo(FuncReturnType)) {
                            // We merge error sets, but still return the original function payload
                            .ErrorUnion => |eu| return (InvokeError || eu.error_set)!eu.payload,

                            // we just merge error sets, the result will be `void` in *no* case (but makes handling easier)
                            .ErrorSet => return (InvokeError || FuncReturnType)!void,

                            // The function doesn't return an error, so we just return InvokeError *or* the function return value.
                            else => return InvokeError!FuncReturnType,
                        }
                    } else {
                        // When not merging error sets, we need to wrap the result into a InvocationResult to handle potential
                        // error unions or sets gracefully in the API.
                        return InvokeError!InvocationResult(FuncReturnType);
                    }
                }

                /// Invokes `func_name` on the remote peer with `args`. Returns either an error or the return value of the remote procedure call.
                /// 
                /// Must be called only after a successful call to `connect()`.
                pub fn invoke(self: *EndPoint, comptime func_name: []const u8, args: anytype) InvokeReturnType(func_name) {
                    std.debug.assert(self.impl != null); // call these only after a successful connection!
                    const FuncPrototype = @field(outbound_spec, func_name);
                    const ArgsTuple = std.meta.ArgsTuple(FuncPrototype);
                    const func_info = @typeInfo(FuncPrototype).Fn;

                    var arg_list: ArgsTuple = undefined;

                    if (args.len != arg_list.len)
                        @compileError("Argument mismatch!");

                    {
                        comptime var i = 0;
                        inline while (i < arg_list.len) : (i += 1) {
                            arg_list[i] = args[i];
                        }
                    }

                    const sequence_id = self.nextSequenceID();

                    try self.writer.writeByte(@enumToInt(CommandId.call));
                    try self.writer.writeIntLittle(u32, @enumToInt(sequence_id));
                    try self.writer.writeIntLittle(u32, func_name.len);
                    try self.writer.writeAll(func_name);
                    try s2s.serialize(self.writer, ArgsTuple, arg_list);

                    try self.waitForResponse(sequence_id);

                    const FuncReturnType = func_info.return_type.?;

                    const result = s2s.deserialize(self.reader, InvocationResult(FuncReturnType)) catch return error.ProtocolViolation;

                    if (config.merge_error_sets) {
                        if (@typeInfo(FuncReturnType) == .ErrorUnion) {
                            return try result.unwrap();
                        } else if (@typeInfo(FuncReturnType) == .ErrorSet) {
                            return result.unwrap();
                        } else {
                            return result.unwrap();
                        }
                    } else {
                        // when we don't merge error sets, we have to return the wrapper struct itself.
                        return result;
                    }
                }

                /// Waits until a response comman is received and validates that against the response id.
                /// Handles in-between calls to other functions.
                /// Leaves the reader in a state so the response can be deserialized directly from the stream.
                fn waitForResponse(self: *EndPoint, sequence_id: SequenceID) !void {
                    while (true) {
                        const cmd_id = try self.reader.readByte();
                        const cmd = std.meta.intToEnum(CommandId, cmd_id) catch return error.ProtocolViolation;
                        switch (cmd) {
                            .call => {
                                try self.processCall();
                            },
                            .response => {
                                const seq = @intToEnum(SequenceID, try self.reader.readIntLittle(u32));
                                if (seq != sequence_id)
                                    return error.ProtocolViolation;
                                return;
                            },
                            .shutdown => return error.ProtocolViolation,
                        }
                    }
                }

                /// Deserializes call information
                fn processCall(self: *EndPoint) !void {
                    const sequence_id = @intToEnum(SequenceID, try self.reader.readIntLittle(u32));
                    const name_length = try self.reader.readIntLittle(u32);
                    if (name_length > max_received_func_name_len)
                        return error.ProtocolViolation;
                    var name_buffer: [max_received_func_name_len]u8 = undefined;
                    const function_name = name_buffer[0..name_length];
                    try self.reader.readNoEof(function_name);

                    inline for (std.meta.fields(InboundSpec)) |fld| {
                        if (std.mem.eql(u8, fld.name, function_name)) {
                            try self.processCallTo(fld.name, sequence_id);
                            return;
                        }
                    }

                    // Client invoked unknown function
                    return error.ProtocolViolation;
                }

                fn processCallTo(self: *EndPoint, comptime function_name: []const u8, sequence_id: SequenceID) !void {
                    const impl_func = @field(Implementation, function_name);
                    const FuncSpec = @field(inbound_spec, function_name);
                    const FuncArgs = std.meta.ArgsTuple(FuncSpec);

                    const ImplFunc = @TypeOf(impl_func);

                    const SpecReturnType = @typeInfo(FuncSpec).Fn.return_type.?;

                    const impl_func_info = @typeInfo(ImplFunc);
                    if (impl_func_info != .Fn)
                        @compileError(@typeName(Implementation) ++ "." ++ function_name ++ " must be a function with invocable signature " ++ @typeName(FuncSpec));

                    const impl_func_fn = impl_func_info.Fn;

                    var invocation_args: FuncArgs = s2s.deserializeAlloc(self.reader, FuncArgs, self.allocator) catch |err| switch (err) {
                        error.UnexpectedData => return error.ProtocolViolation,
                        else => |e| return e,
                    };
                    defer s2s.free(self.allocator, FuncArgs, &invocation_args);

                    const result: SpecReturnType = if (impl_func_fn.args.len == invocation_args.len)
                        // invocation without self
                        @call(.{}, impl_func, invocation_args)
                    else if (impl_func_fn.args.len == invocation_args.len + 1)
                        // invocation with self
                        if (@typeInfo(impl_func_fn.args[0].arg_type.?) == .Pointer)
                            @call(.{}, impl_func, .{self.impl.?} ++ invocation_args)
                        else
                            @call(.{}, impl_func, .{self.impl.?.*} ++ invocation_args)
                    else
                        @compileError("Parameter mismatch for " ++ function_name);

                    try self.writer.writeByte(@enumToInt(CommandId.response));
                    try self.writer.writeIntLittle(u32, @enumToInt(sequence_id));
                    try s2s.serialize(self.writer, InvocationResult(SpecReturnType), invocationResult(SpecReturnType, result));
                }

                fn nextSequenceID(self: *EndPoint) SequenceID {
                    const next = self.sequence_id;
                    self.sequence_id += 1;
                    return @intToEnum(SequenceID, next);
                }
            };
        }
    };
}

const protocol_magic = [4]u8{ 0x34, 0xa3, 0x8a, 0x54 };
const current_version = 0;

const CommandId = enum(u8) {
    /// Begins a function invocation.
    ///
    /// message format:
    /// - sequence id (u32)
    /// - function name length (u32)
    /// - function name ([function name length]u8)
    /// - serialized function arguments
    call = 1,

    /// Returns the data for a function invocation.
    ///
    /// message format:
    /// - sequence id (u32)
    /// - serialized InvocationResult(function return value)
    response = 2,

    /// Forces a peer to leave `acceptCalls()`.
    ///
    /// message format:
    /// - (no data)
    shutdown = 3,
};

const SequenceID = enum(u32) { _ };

/// Computes the return type of the given function type.
fn ReturnType(comptime Func: type) type {
    return @typeInfo(Func).Fn.return_type.?;
}

/// Constructor for InvocationResult
fn invocationResult(comptime T: type, value: T) InvocationResult(T) {
    return .{ .value = value };
}

fn validateSpec(comptime funcs: anytype) void {
    const T = @TypeOf(funcs);
    inline for (std.meta.fields(T)) |fld| {
        if (fld.field_type != type)
            @compileError("All fields of .host or .client must be function types!");
        const field_info = @typeInfo(@field(funcs, fld.name));

        if (field_info != .Fn)
            @compileError("All fields of .host or .client must be function types!");

        const func_info: std.builtin.TypeInfo.Fn = field_info.Fn;
        if (func_info.is_generic) @compileError("Cannot handle generic functions");
        for (func_info.args) |arg| {
            if (arg.is_generic) @compileError("Cannot handle generic functions");
            if (arg.arg_type == null) @compileError("Cannot handle generic functions");
        }
        if (func_info.return_type == null) @compileError("Cannot handle generic functions");
    }
}

test "CreateDefinition" {
    const CreateError = error{ OutOfMemory, UnknownCounter };
    const UsageError = error{ OutOfMemory, UnknownCounter };
    const RcpDefinition = CreateDefinition(.{
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

    _ = RcpDefinition;
}

test "invoke function (emulated host)" {
    const RcpDefinition = CreateDefinition(.{
        .host = .{
            .some = fn (a: u32, b: f32, c: []const u8) void,
        },
        .client = .{},
    });

    const ClientImpl = struct {};

    var output_stream = std.ArrayList(u8).init(std.testing.allocator);
    defer output_stream.deinit();

    const input_data = comptime blk: {
        var buffer: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var writer = stream.writer();

        try writer.writeAll(&protocol_magic);
        try writer.writeByte(current_version);

        try writer.writeByte(@enumToInt(CommandId.response));
        try writer.writeIntLittle(u32, 0); // first sequence id

        try s2s.serialize(writer, InvocationResult(void), invocationResult(void, {}));

        break :blk stream.getWritten();
    };
    var input_stream = std.io.fixedBufferStream(@as([]const u8, input_data));

    const EndPoint = RcpDefinition.ClientEndPoint(std.io.FixedBufferStream([]const u8).Reader, std.ArrayList(u8).Writer, ClientImpl);

    var end_point = EndPoint.init(std.testing.allocator, input_stream.reader(), output_stream.writer());

    var impl = ClientImpl{};
    try end_point.connect(&impl);

    try end_point.invoke("some", .{ 1, 2, "hello, world!" });

    // std.debug.print("host to client: {}\n", .{std.fmt.fmtSliceHexUpper(input_data)});
    // std.debug.print("client to host: {}\n", .{std.fmt.fmtSliceHexUpper(output_stream.items)});
}

test "invoke function (emulated client, no self parameter)" {
    const RcpDefinition = CreateDefinition(.{
        .host = .{
            .some = fn (a: u32, b: f32, c: []const u8) u32,
        },
        .client = .{},
    });

    const HostImpl = struct {
        fn some(a: u32, b: f32, c: []const u8) u32 {
            std.debug.print("some({}, {d}, \"{s}\");\n", .{ a, b, c });
            return a + @floatToInt(u32, b);
        }
    };

    var output_stream = std.ArrayList(u8).init(std.testing.allocator);
    defer output_stream.deinit();

    const input_data = comptime blk: {
        var buffer: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var writer = stream.writer();

        try writer.writeAll(&protocol_magic);
        try writer.writeByte(current_version);

        try writer.writeByte(@enumToInt(CommandId.call));
        try writer.writeIntLittle(u32, 1337); // first sequence id
        try writer.writeIntLittle(u32, "some".len);
        try writer.writeAll("some");

        try s2s.serialize(writer, std.meta.Tuple(&.{ u32, f32, []const u8 }), .{
            .@"0" = 1334,
            .@"1" = std.math.pi,
            .@"2" = "Hello, Host!",
        });

        try writer.writeByte(@enumToInt(CommandId.shutdown));

        break :blk stream.getWritten();
    };
    var input_stream = std.io.fixedBufferStream(@as([]const u8, input_data));

    const EndPoint = RcpDefinition.HostEndPoint(std.io.FixedBufferStream([]const u8).Reader, std.ArrayList(u8).Writer, HostImpl);

    var end_point = EndPoint.init(std.testing.allocator, input_stream.reader(), output_stream.writer());

    var impl = HostImpl{};
    try end_point.connect(&impl);

    try end_point.acceptCalls();

    // std.debug.print("host to client: {}\n", .{std.fmt.fmtSliceHexUpper(input_data)});
    // std.debug.print("client to host: {}\n", .{std.fmt.fmtSliceHexUpper(output_stream.items)});
}

test "invoke function (emulated client, with self parameter)" {
    const RcpDefinition = CreateDefinition(.{
        .host = .{
            .some = fn (a: u32, b: f32, c: []const u8) u32,
        },
        .client = .{},
    });

    const HostImpl = struct {
        dummy: u8 = 0,

        fn some(self: @This(), a: u32, b: f32, c: []const u8) u32 {
            std.debug.print("some({}, {}, {d}, \"{s}\");\n", .{ self.dummy, a, b, c });
            return a + @floatToInt(u32, b);
        }
    };

    var output_stream = std.ArrayList(u8).init(std.testing.allocator);
    defer output_stream.deinit();

    const input_data = comptime blk: {
        var buffer: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var writer = stream.writer();

        try writer.writeAll(&protocol_magic);
        try writer.writeByte(current_version);

        try writer.writeByte(@enumToInt(CommandId.call));
        try writer.writeIntLittle(u32, 1337); // first sequence id
        try writer.writeIntLittle(u32, "some".len);
        try writer.writeAll("some");

        try s2s.serialize(writer, std.meta.Tuple(&.{ u32, f32, []const u8 }), .{
            .@"0" = 1334,
            .@"1" = std.math.pi,
            .@"2" = "Hello, Host!",
        });

        try writer.writeByte(@enumToInt(CommandId.shutdown));

        break :blk stream.getWritten();
    };
    var input_stream = std.io.fixedBufferStream(@as([]const u8, input_data));

    const EndPoint = RcpDefinition.HostEndPoint(std.io.FixedBufferStream([]const u8).Reader, std.ArrayList(u8).Writer, HostImpl);

    var end_point = EndPoint.init(std.testing.allocator, input_stream.reader(), output_stream.writer());

    var impl = HostImpl{ .dummy = 123 };
    try end_point.connect(&impl);

    try end_point.acceptCalls();

    // std.debug.print("host to client: {}\n", .{std.fmt.fmtSliceHexUpper(input_data)});
    // std.debug.print("client to host: {}\n", .{std.fmt.fmtSliceHexUpper(output_stream.items)});
}

test "invoke function with callback (emulated host, no self parameter)" {
    const RcpDefinition = CreateDefinition(.{
        .host = .{
            .some = fn (a: u32, b: f32, c: []const u8) void,
        },
        .client = .{
            .callback = fn (msg: []const u8) void,
        },
    });

    const ClientImpl = struct {
        pub fn callback(msg: []const u8) void {
            std.debug.print("callback(\"{s}\");\n", .{msg});
        }
    };

    var output_stream = std.ArrayList(u8).init(std.testing.allocator);
    defer output_stream.deinit();

    const input_data = comptime blk: {
        var buffer: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var writer = stream.writer();

        try writer.writeAll(&protocol_magic);
        try writer.writeByte(current_version);

        try writer.writeByte(@enumToInt(CommandId.call));
        try writer.writeIntLittle(u32, 1337); // first sequence id
        try writer.writeIntLittle(u32, "callback".len);
        try writer.writeAll("callback");

        try s2s.serialize(writer, std.meta.Tuple(&.{[]const u8}), .{
            .@"0" = "Hello, World!",
        });

        try writer.writeByte(@enumToInt(CommandId.response));
        try writer.writeIntLittle(u32, 0); // first sequence id

        try s2s.serialize(writer, InvocationResult(void), invocationResult(void, {}));

        break :blk stream.getWritten();
    };
    var input_stream = std.io.fixedBufferStream(@as([]const u8, input_data));

    const EndPoint = RcpDefinition.ClientEndPoint(std.io.FixedBufferStream([]const u8).Reader, std.ArrayList(u8).Writer, ClientImpl);

    var end_point = EndPoint.init(std.testing.allocator, input_stream.reader(), output_stream.writer());

    var impl = ClientImpl{};
    try end_point.connect(&impl);

    try end_point.invoke("some", .{ 1, 2, "hello, world!" });

    // std.debug.print("host to client: {}\n", .{std.fmt.fmtSliceHexUpper(input_data)});
    // // std.debug.print("client to host: {}\n", .{std.fmt.fmtSliceHexUpper(output_stream.items)});
}

test "invoke function with callback (emulated host, with self parameter)" {
    const RcpDefinition = CreateDefinition(.{
        .host = .{
            .some = fn (a: u32, b: f32, c: []const u8) void,
        },
        .client = .{
            .callback = fn (msg: []const u8) void,
        },
    });

    const ClientImpl = struct {
        dummy: u8 = 0, // required to print pointer

        pub fn callback(self: *@This(), msg: []const u8) void {
            std.debug.print("callback({*}, \"{s}\");\n", .{ self, msg });
        }
    };

    var output_stream = std.ArrayList(u8).init(std.testing.allocator);
    defer output_stream.deinit();

    const input_data = comptime blk: {
        var buffer: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var writer = stream.writer();

        try writer.writeAll(&protocol_magic);
        try writer.writeByte(current_version);

        try writer.writeByte(@enumToInt(CommandId.call));
        try writer.writeIntLittle(u32, 1337); // first sequence id
        try writer.writeIntLittle(u32, "callback".len);
        try writer.writeAll("callback");

        try s2s.serialize(writer, std.meta.Tuple(&.{[]const u8}), .{
            .@"0" = "Hello, World!",
        });

        try writer.writeByte(@enumToInt(CommandId.response));
        try writer.writeIntLittle(u32, 0); // first sequence id

        try s2s.serialize(writer, InvocationResult(void), invocationResult(void, {}));

        break :blk stream.getWritten();
    };
    var input_stream = std.io.fixedBufferStream(@as([]const u8, input_data));

    const EndPoint = RcpDefinition.ClientEndPoint(std.io.FixedBufferStream([]const u8).Reader, std.ArrayList(u8).Writer, ClientImpl);

    var end_point = EndPoint.init(std.testing.allocator, input_stream.reader(), output_stream.writer());

    var impl = ClientImpl{};
    try end_point.connect(&impl);

    try end_point.invoke("some", .{ 1, 2, "hello, world!" });

    // std.debug.print("host to client: {}\n", .{std.fmt.fmtSliceHexUpper(input_data)});
    // std.debug.print("client to host: {}\n", .{std.fmt.fmtSliceHexUpper(output_stream.items)});
}
