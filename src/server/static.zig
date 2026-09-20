//! `server/static.zig` —— 静态资源服务（让浏览器**同源**打开 UI）。
//!
//! ## 为什么是内核自己发静态资源（而不是让前端 dev server 跨域 fetch）
//!
//! 已定决策是 **Web-first**（AGENTS.md #2/#3）。同源方案有两个实际好处：
//!   1. **不需要 CORS** —— 少一整类预检/凭据问题；
//!   2. **交付物仍是单二进制**（占位页 `@embedFile` 进二进制），桌面壳不用另外带一份前端。
//!
//! ## 两个来源，按优先级
//!
//! 1. `<web_root>/…`（默认 `./web`）—— **设计产物放这里，立即生效，不用重新编译**；
//! 2. 内嵌占位页（`placeholder.html`）—— 目录不存在时兜底，**保证 `/` 永不 404**。
//!
//! ## 安全：路径围栏
//!
//! 静态路径是**外部输入**，必须防 `../../` 逃逸。这里用词法归一化 + 前缀判定
//! （与 `perm/path.zig`、`util/fsio.zig` 同一口径：**不解析符号链接**，那属于二期）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const util = @import("util");

const placeholder_html = @embedFile("placeholder.html");

pub const max_asset_bytes: usize = 16 << 20;

pub const ContentType = struct { mime: []const u8, cache: []const u8 };

pub fn contentTypeOf(path: []const u8) ContentType {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".html")) return .{ .mime = "text/html; charset=utf-8", .cache = "no-cache" };
    if (std.ascii.eqlIgnoreCase(ext, ".js")) return .{ .mime = "text/javascript; charset=utf-8", .cache = "no-cache" };
    if (std.ascii.eqlIgnoreCase(ext, ".mjs")) return .{ .mime = "text/javascript; charset=utf-8", .cache = "no-cache" };
    if (std.ascii.eqlIgnoreCase(ext, ".css")) return .{ .mime = "text/css; charset=utf-8", .cache = "no-cache" };
    if (std.ascii.eqlIgnoreCase(ext, ".json")) return .{ .mime = "application/json; charset=utf-8", .cache = "no-cache" };
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return .{ .mime = "image/svg+xml", .cache = "no-cache" };
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return .{ .mime = "image/png", .cache = "no-cache" };
    if (std.ascii.eqlIgnoreCase(ext, ".jpg")) return .{ .mime = "image/jpeg", .cache = "no-cache" };
    if (std.ascii.eqlIgnoreCase(ext, ".jpeg")) return .{ .mime = "image/jpeg", .cache = "no-cache" };
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return .{ .mime = "image/webp", .cache = "no-cache" };
    if (std.ascii.eqlIgnoreCase(ext, ".ico")) return .{ .mime = "image/x-icon", .cache = "no-cache" };
    if (std.ascii.eqlIgnoreCase(ext, ".woff2")) return .{ .mime = "font/woff2", .cache = "no-cache" };
    if (std.ascii.eqlIgnoreCase(ext, ".txt")) return .{ .mime = "text/plain; charset=utf-8", .cache = "no-cache" };
    if (std.ascii.eqlIgnoreCase(ext, ".map")) return .{ .mime = "application/json; charset=utf-8", .cache = "no-cache" };
    return .{ .mime = "application/octet-stream", .cache = "no-cache" };
}

pub const Asset = struct {
    body: []const u8,
    content_type: []const u8,
    cache_control: []const u8,
    /// 是否来自内嵌占位页（诊断用）
    embedded: bool = false,
    /// 需要释放（读自磁盘）
    owned: bool = false,

    pub fn deinit(self: Asset, gpa: Allocator) void {
        if (self.owned) gpa.free(self.body);
    }
};

/// 解析一个静态请求路径。
///
/// `path` 是 URL 路径（可能带 query 已在调用方剥离）。返回 null = 应走 404。
/// 注意：**返回 null 与"文件不存在"是同一件事** —— 调用方统一 404，不泄漏目录结构。
pub fn resolve(io: Io, gpa: Allocator, web_root: ?[]const u8, url_path: []const u8) !?Asset {
    // 1) 先从磁盘找
    if (web_root) |root| {
        var rel_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        // 归一化失败（试图逃逸）= 直接当"不存在"，不是错误
        const rel = normalizeRel(url_path, &rel_buf) catch null;
        // `/`、`/index.html` 的目录形式 → index.html
        const effective: []const u8 = rel orelse "index.html";
        if (try loadFromDisk(io, gpa, root, effective)) |a| return a;
    }

    // 2) 兜底：只有根路径与显式的占位路径才给占位页
    if (std.mem.eql(u8, url_path, "/") or std.mem.eql(u8, url_path, "/index.html")) {
        return .{
            .body = placeholder_html,
            .content_type = "text/html; charset=utf-8",
            .cache_control = "no-cache",
            .embedded = true,
        };
    }
    return null;
}

/// `rel` 必须是**已归一化的相对路径**（由 `normalizeRel` 产出，或硬编码的 `index.html`）。
fn loadFromDisk(io: Io, gpa: Allocator, root: []const u8, rel: []const u8) !?Asset {
    const full = try std.fs.path.join(gpa, &.{ root, rel });
    defer gpa.free(full);

    // 目录 → 尝试 index.html
    if (util.io.isDir(io, full)) {
        const idx = try std.fs.path.join(gpa, &.{ full, "index.html" });
        defer gpa.free(idx);
        return readAsset(io, gpa, idx);
    }
    if (try readAsset(io, gpa, full)) |a| return a;
    return null;
}

fn readAsset(io: Io, gpa: Allocator, full: []const u8) !?Asset {
    const body = util.fsio.readIfExists(io, gpa, full, max_asset_bytes) catch return null;
    const owned = body orelse return null;
    const ct = contentTypeOf(full);
    return .{
        .body = owned,
        .content_type = ct.mime,
        .cache_control = ct.cache,
        .owned = true,
    };
}

/// 把 URL 路径归一化成**不含 `..`、不以 `/` 开头**的相对路径。
/// 任何试图逃出 root 的路径 → `null`。
pub fn normalizeRel(url_path: []const u8, buf: []u8) !?[]const u8 {
    var out: usize = 0;
    var it = std.mem.tokenizeAny(u8, url_path, "/\\");
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) return null; // 直接拒绝，不做回溯
        if (std.mem.indexOfScalar(u8, seg, 0) != null) return null;
        if (out + seg.len + 1 > buf.len) return error.NameTooLong;
        if (out > 0) {
            buf[out] = '/';
            out += 1;
        }
        @memcpy(buf[out .. out + seg.len], seg);
        out += seg.len;
    }
    if (out == 0) return null;
    return buf[0..out];
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "static: 内容类型" {
    try testing.expectEqualStrings("text/html; charset=utf-8", contentTypeOf("index.html").mime);
    try testing.expectEqualStrings("text/javascript; charset=utf-8", contentTypeOf("app.js").mime);
    try testing.expectEqualStrings("image/png", contentTypeOf("logo.PNG").mime);
    try testing.expectEqualStrings("application/octet-stream", contentTypeOf("a.bin").mime);
}

test "static: 路径围栏拒绝逃逸" {
    var buf: [256]u8 = undefined;
    try testing.expect((try normalizeRel("../../etc/passwd", &buf)) == null);
    try testing.expect((try normalizeRel("/../secret", &buf)) == null);
    try testing.expect((try normalizeRel("/a/../b", &buf)) == null);
    try testing.expectEqualStrings("assets/app.js", (try normalizeRel("/assets/app.js", &buf)).?);
    try testing.expectEqualStrings("a/b", (try normalizeRel("a//./b", &buf)).?);
    try testing.expect((try normalizeRel("/", &buf)) == null);
}

test "static: 无 web 目录时 / 给内嵌占位页（永不 404）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const a = try resolve(threaded.io(), testing.allocator, "/nonexistent-web-root-xyz", "/");
    try testing.expect(a != null);
    defer a.?.deinit(testing.allocator);
    try testing.expect(a.?.embedded);
    try testing.expect(std.mem.indexOf(u8, a.?.body, "Zigent") != null);
}

test "static: 未知路径 → null（走 404）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const a = try resolve(threaded.io(), testing.allocator, "/nonexistent-web-root-xyz", "/does-not-exist.js");
    try testing.expect(a == null);
}

test "static: 磁盘优先于内嵌占位页" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rnd = try util.io.randomHex(io, testing.allocator, 6);
    defer testing.allocator.free(rnd);
    const root = try std.fmt.allocPrint(testing.allocator, "/tmp/zigent-static-test-{s}", .{rnd});
    defer testing.allocator.free(root);
    defer util.io.removeTree(io, root) catch {};
    try util.io.mkdirp(io, root);

    const idx = try std.fs.path.join(testing.allocator, &.{ root, "index.html" });
    defer testing.allocator.free(idx);
    try util.io.writeFile(io, idx, "<h1>designed</h1>");

    const a = try resolve(io, testing.allocator, root, "/");
    try testing.expect(a != null);
    defer a.?.deinit(testing.allocator);
    try testing.expect(!a.?.embedded);
    try testing.expectEqualStrings("<h1>designed</h1>", a.?.body);
}
