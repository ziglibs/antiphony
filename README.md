# Antiphony

A simple Zig remote procedure call library.

![Project Logo](design/logo.png)

## Features

- Transport layer agnostic
- Support for nearly every non-generic function signature.
- Nestable remote calls (peer calls host calls peer calls host calls ...)
- Easy to use

## API

```zig
// (comptime details left out for brevity)

pub fn CreateDefinition(spec: anytype) type {
    return struct {
        pub fn HostEndPoint(Reader: type, Writer: type, Implementation: type) type {
            return CreateEndPoint(.host, Reader, Writer, Implementation);
        }
        pub fn ClientEndPoint(Reader: type, Writer: type, Implementation: type) type {
            return CreateEndPoint(.client, Reader, Writer, Implementation);
        }
        pub fn CreateEndPoint(role: Role, ReaderType: type, WriterType: type, ImplementationType: type) type {
            return struct {
                const EndPoint = @This();

                pub const Reader = Reader;
                pub const Writer = Writer;
                pub const Implementation = Implementation;

                pub const IoError = error{ ... };
                pub const ProtocolError = error{ ... };
                pub const InvokeError = error{ ... };
                pub const ConnectError = error{ ... };

                pub fn init(allocator: std.mem.Allocator, reader: Reader, writer: Writer) EndPoint;
                pub fn destroy(self: *EndPoint) void;
                pub fn connect(self: *EndPoint, impl: *Implementation) ConnectError!void;
                pub fn shutdown(self: *EndPoint) IoError!void;
                pub fn acceptCalls(self: *EndPoint) InvokeError!void;
                pub fn invoke(self: *EndPoint, func_name: []const u8, args: anytype) InvokeError!Result(func_name);
            };
        }
    };
}

// Example for CreateDefinition(spec):
const Definition = antiphony.CreateDefinition(.{
    .host = .{
        // add all functions the host implements:
        .createCounter = fn () CreateError!u32,
        .destroyCounter = fn (u32) void,
        .increment = fn (u32, u32) UsageError!u32,
        .getCount = fn (u32) UsageError!u32,
    },
    .client = .{
        // add all functions the client implements:
        .signalError = fn (msg: []const u8) void,
    },

    // this is optional and can be left out:
    .config = .{
        // defines how to handle remote error sets:
        .merge_error_sets = true,
    },
});
```

## Project Status

This project is currently in testing phase, all core features are already implemented and functional.

## Contribution

Contributions are welcome as long as they don't change unnecessarily increase the complexity of the library. This library is meant to be the bare minimum RPC implementation that is well usable. Bug fixes and updates to new versions are always welcome.

### Compile and run the examples

```sh-session
[user@host antiphony]$ zig build install
[user@host antiphony]$ ./zig-out/bin/socketpair-example
info: first increment:  0
info: second increment: 5
info: third increment:  8
info: final count:      15
error: remote error: This counter was already deleted!
info: error while calling getCount()  with invalid handle: UnknownCounter
[user@host antiphony]$
```

### Run the test suite

```sh-session
[user@host antiphony]$ zig build test
Test [3/6] test "invoke function (emulated client, no self parameter)"... some(1334, 3.1415927410125732, "Hello, Host!");
Test [4/6] test "invoke function (emulated client, with self parameter)"... some(123, 1334, 3.1415927410125732, "Hello, Host!");
Test [5/6] test "invoke function with callback (emulated host, no self parameter)"... callback("Hello, World!");
Test [6/6] test "invoke function with callback (emulated host, with self parameter)"... callback(ClientImpl@7ffd33f6cdc0, "Hello, World!");
All 6 tests passed.
[user@host antiphony]$
```
