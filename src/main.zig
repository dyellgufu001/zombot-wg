const std = @import("std");
const c = @cImport({
    @cInclude("ini.h");
});
const Allocator = std.mem.Allocator;

fn isPortAvailable(port: u16) bool {
    const s = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP) catch {
        std.debug.print("uh oh\n", .{});
        unreachable;
    };

    defer std.posix.close(s);

    const addr = std.net.Address.parseIp("0.0.0.0", port) catch unreachable;
    std.posix.bind(s, &addr.any, addr.getOsSockLen()) catch return false;
    return true;
}

const Config = struct {
    const Self = @This();

    const Pair = struct {
        name: []const u8,
        value: []const u8,
    };

    const Section = struct {
        name: []const u8,
        pairs: std.ArrayList(Pair),

        fn findPairByName(self: Section, name: []const u8) ?*Pair {
            for (self.pairs.items) |*pair| {
                if (std.mem.eql(u8, pair.*.name, name)) return pair;
            }

            return null;
        }
    };

    alloc: Allocator,
    sections: std.ArrayList(Section),

    ip: []const u8 = undefined,
    port: u16 = 0,

    fn parse(alloc: Allocator, path: []const u8) !Self {
        var config: Self = .{
            .alloc = alloc,
            .sections = std.ArrayList(Section).init(alloc),
        };

        const result = c.ini_parse(@alignCast(@ptrCast(path.ptr)), ini_handler, @ptrCast(&config));
        if (result < 0) {
            std.debug.print("ini parse error {d}\n", .{result});
            return error.IniParse;
        }

        return config;
    }

    fn findSectionByName(self: Self, name: []const u8) ?*Section {
        for (self.sections.items) |*section| {
            if (std.mem.eql(u8, section.*.name, name)) return section;
        }

        return null;
    }

    fn ini_handler(user: ?*anyopaque, section_name: [*c]const u8, name: [*c]const u8, value: [*c]const u8) callconv(.C) c_int {
        const self: *Self = @alignCast(@ptrCast(user.?));
        var section = self.findSectionByName(std.mem.span(section_name));
        if (section) |_| {} else {
            self.sections.append(.{
                .name = self.alloc.dupe(u8, std.mem.span(section_name)) catch unreachable,
                .pairs = std.ArrayList(Pair).init(self.alloc),
            }) catch unreachable;
            section = self.findSectionByName(std.mem.span(section_name));
        }

        if (std.mem.eql(u8, std.mem.span(section_name), "Peer") and std.mem.eql(u8, std.mem.span(name), "Endpoint")) {
            var split = std.mem.splitAny(u8, std.mem.span(value), ":");

            self.ip = self.alloc.dupe(u8, split.next().?) catch unreachable;
            self.port = std.fmt.parseInt(u16, split.next().?, 10) catch unreachable;
        }

        section.?.pairs.append(.{
            .name = self.alloc.dupe(u8, std.mem.span(name)) catch unreachable,
            .value = self.alloc.dupe(u8, std.mem.span(value)) catch unreachable,
        }) catch unreachable;

        return 0;
    }

    fn write(self: *const Self, path: []const u8) !void {
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();

        const writer = f.writer();

        for (self.sections.items) |section| {
            try writer.print("[{s}]\n", .{section.name});
            for (section.pairs.items) |pair| {
                try writer.print("{s} = {s}\n", .{ pair.name, pair.value });
            }
            _ = try writer.write("\n");
        }
    }

    fn updateListenPort(self: *Self, path: []u8) !u16 {
        var listen_port = std.crypto.random.intRangeAtMost(u16, 32768, 65535);
        while (!isPortAvailable(listen_port)) : (listen_port = std.crypto.random.intRangeAtMost(u16, 32768, 65535)) {}

        if (self.findSectionByName("Interface").?.findPairByName("ListenPort")) |pair| {
            self.alloc.free(pair.value);
            pair.*.value = try std.fmt.allocPrint(self.alloc, "{d}", .{listen_port});
        } else {
            try self.findSectionByName("Interface").?.pairs.append(.{
                .name = try self.alloc.dupe(u8, "ListenPort"),
                .value = try std.fmt.allocPrint(self.alloc, "{d}", .{listen_port}),
            });
        }

        try self.write(path);

        return listen_port;
    }

    fn deinit(self: Self) void {
        for (self.sections.items) |section| {
            for (section.pairs.items) |pair| {
                self.alloc.free(pair.name);
                self.alloc.free(pair.value);
            }
            self.alloc.free(section.name);
            section.pairs.deinit();
        }
        self.alloc.free(self.ip);
        self.sections.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        return error.NoConfig;
    }

    const wg = if (args.len > 2) args[2] else "awg-quick";

    var config = try Config.parse(alloc, args[1]);
    defer config.deinit();

    const server_addr = try std.net.Address.parseIp(config.ip, config.port);
    const listen_port = try config.updateListenPort(args[1]);

    std.debug.print("listen port {d}\n", .{listen_port});

    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);

    const listen_addr = try std.net.Address.parseIp("0.0.0.0", listen_port);
    try std.posix.bind(socket, &listen_addr.any, listen_addr.getOsSockLen());

    const rand = std.crypto.random;
    var buf: [1024]u8 = undefined;
    const size = rand.intRangeLessThan(usize, 32, buf.len);
    rand.bytes(buf[0..size]);
    _ = try std.posix.sendto(socket, buf[0..size], 0, &server_addr.any, server_addr.getOsSockLen());

    std.posix.close(socket);

    var cmd = std.process.Child.init(&[_][]const u8{ "sudo", wg, "up", args[1] }, alloc);
    try cmd.spawn();
    _ = try cmd.wait();
}
