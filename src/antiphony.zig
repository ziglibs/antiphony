const std = @import("std");
const s2s = @import("s2s");

const logger = std.log.scoped(.antiphony_rpc);

const protocol_magic = [4]u8{ 0x34, 0xa3, 0x8a, 0x54 };
const current_version = 0;

pub const Role = enum { host, client };

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
    /// - serialized function return value
    response = 2,

    /// Forces a peer to leave `acceptCalls()`.
    ///
    /// message format:
    /// - (no data)
    shutdown = 3,
};

const SequenceID = enum(u32) { _ };

fn ReturnType(comptime Func: type) type {
    return @typeInfo(Func).Fn.return_type.?;
}

pub fn CreateDefinition(comptime spec: anytype) type {
    const host_spec = spec.host;
    const client_spec = spec.client;

    comptime validateSpec(host_spec);
    comptime validateSpec(client_spec);

    return struct {
        const Self = @This();

        pub fn HostBinder(comptime Reader: type, comptime Writer: type, comptime Implementation: type) type {
            return CreateBinder(.host, Reader, Writer, Implementation);
        }

        pub fn ClientBinder(comptime Reader: type, comptime Writer: type, comptime Implementation: type) type {
            return CreateBinder(.client, Reader, Writer, Implementation);
        }

        pub fn CreateBinder(comptime role: Role, comptime ReaderType: type, comptime WriterType: type, comptime ImplementationType: type) type {
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
                pub const Binder = @This();
                pub const Reader = ReaderType;
                pub const Writer = WriterType;
                pub const Implementation = ImplementationType;

                pub const IoError = Reader.Error || Writer.Error || error{EndOfStream};
                pub const ProtocolError = error{ ProtocolViolation, InvalidProtocol, ProtocolMismatch };
                const InvokeError = IoError || ProtocolError || std.mem.Allocator.Error;

                allocator: std.mem.Allocator,
                reader: Reader,
                writer: Writer,

                sequence_id: u32 = 0,
                impl: ?*Implementation = null,

                pub fn init(allocator: std.mem.Allocator, reader: Reader, writer: Writer) Binder {
                    return Binder{
                        .allocator = allocator,
                        .reader = reader,
                        .writer = writer,
                    };
                }
                pub fn destroy(self: *Binder) void {
                    self.* = undefined;
                }

                const ConnectError = IoError || ProtocolError;
                pub fn connect(self: *Binder, impl: *Implementation) !void {
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

                /// Waits for incoming calls and handles them till the client closes the connection.
                pub fn acceptCalls(self: *Binder) InvokeError!void {
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

                pub fn invoke(self: *Binder, comptime func_name: []const u8, args: anytype) InvokeError!ReturnType(@field(outbound_spec, func_name)) {
                    const FuncPrototype = @field(outbound_spec, func_name);
                    const ArgsTuple = std.meta.ArgsTuple(FuncPrototype);
                    const func_info = @typeInfo(FuncPrototype).Fn;

                    var arg_list: ArgsTuple = undefined;
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

                    const result = s2s.deserialize(self.reader, func_info.return_type.?) catch return error.ProtocolViolation;

                    return result;
                }

                /// Waits until a response comman is received and validates that against the response id.
                /// Handles in-between calls to other functions.
                /// Leaves the reader in a state so the response can be deserialized directly from the stream.
                fn waitForResponse(self: *Binder, sequence_id: SequenceID) !void {
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
                fn processCall(self: *Binder) !void {
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

                fn processCallTo(self: *Binder, comptime function_name: []const u8, sequence_id: SequenceID) !void {
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
                    try s2s.serialize(self.writer, SpecReturnType, result);
                }

                fn nextSequenceID(self: *Binder) SequenceID {
                    const next = self.sequence_id;
                    self.sequence_id += 1;
                    return @intToEnum(SequenceID, next);
                }
            };
        }
    };
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

        try s2s.serialize(writer, void, {});

        break :blk stream.getWritten();
    };
    var input_stream = std.io.fixedBufferStream(@as([]const u8, input_data));

    const Binder = RcpDefinition.ClientBinder(std.io.FixedBufferStream([]const u8).Reader, std.ArrayList(u8).Writer, ClientImpl);

    var binder = Binder.init(std.testing.allocator, input_stream.reader(), output_stream.writer());

    var impl = ClientImpl{};
    try binder.connect(&impl);

    try binder.invoke("some", .{ 1, 2, "hello, world!" });

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

    const Binder = RcpDefinition.HostBinder(std.io.FixedBufferStream([]const u8).Reader, std.ArrayList(u8).Writer, HostImpl);

    var binder = Binder.init(std.testing.allocator, input_stream.reader(), output_stream.writer());

    var impl = HostImpl{};
    try binder.connect(&impl);

    try binder.acceptCalls();

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

    const Binder = RcpDefinition.HostBinder(std.io.FixedBufferStream([]const u8).Reader, std.ArrayList(u8).Writer, HostImpl);

    var binder = Binder.init(std.testing.allocator, input_stream.reader(), output_stream.writer());

    var impl = HostImpl{ .dummy = 123 };
    try binder.connect(&impl);

    try binder.acceptCalls();

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

        try s2s.serialize(writer, void, {});

        break :blk stream.getWritten();
    };
    var input_stream = std.io.fixedBufferStream(@as([]const u8, input_data));

    const Binder = RcpDefinition.ClientBinder(std.io.FixedBufferStream([]const u8).Reader, std.ArrayList(u8).Writer, ClientImpl);

    var binder = Binder.init(std.testing.allocator, input_stream.reader(), output_stream.writer());

    var impl = ClientImpl{};
    try binder.connect(&impl);

    try binder.invoke("some", .{ 1, 2, "hello, world!" });

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

        try s2s.serialize(writer, void, {});

        break :blk stream.getWritten();
    };
    var input_stream = std.io.fixedBufferStream(@as([]const u8, input_data));

    const Binder = RcpDefinition.ClientBinder(std.io.FixedBufferStream([]const u8).Reader, std.ArrayList(u8).Writer, ClientImpl);

    var binder = Binder.init(std.testing.allocator, input_stream.reader(), output_stream.writer());

    var impl = ClientImpl{};
    try binder.connect(&impl);

    try binder.invoke("some", .{ 1, 2, "hello, world!" });

    // std.debug.print("host to client: {}\n", .{std.fmt.fmtSliceHexUpper(input_data)});
    // std.debug.print("client to host: {}\n", .{std.fmt.fmtSliceHexUpper(output_stream.items)});
}
