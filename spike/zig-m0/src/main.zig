//! M0 spike 入口。
//!
//! 用法：
//! zig build run -- --version # 契约 #5
//! zig build run -- serve # E3：起本地 HTTP/SSE 服务（主命令）
//! zig build run -- serve --token HEX # 壳传入 token（default 自生成）
//! zig build run -- e1 # E1 并发/取消探针
//! zig build run -- e4 # E4 内存所有权探针
//! zig build run -- e5 # E5 兼容性说明
//! zig build test # 全部纯逻辑测试（不需要网络）
//! zig build test-tsan # E1 的数据竞争探针

const std = @import("std");
const handshake = @import("handshake.zig");
const http_server = @import("http_server.zig");
const e1 = @import("e1_io.zig");
const e4 = @import("e4_memory.zig");

pub const VERSION = http_server.VERSION;

fn out(comptime fmt: []const u8, args: anytype) void {
 std.debug.print(fmt ++ "\n", args); // stderr（spike 里日志统一走 stderr）
}

pub fn main() !void {
 var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
 defer _ = gpa_state.deinit();
 const gpa = gpa_state.allocator();

 const args = try std.process.argsAlloc(gpa);
 defer std.process.argsFree(gpa, args);

 var cmd: []const u8 = "help";
 var token_hex: ?[]const u8 = null;

 var i: usize = 1;
 while (i < args.len) : (i += 1) {
 const a = args[i];
 if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-v")) {
 // 契约 #5：壳与更新器都靠它判断版本
 try std.posix.write(std.posix.STDOUT_FILENO, VERSION ++ "\n");
 return;
 } else if (std.mem.eql(u8, a, "--token")) {
 i += 1;
 if (i < args.len) token_hex = args[i];
 } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
 cmd = "help";
 } else {
 cmd = a;
 }
 }

 if (std.mem.eql(u8, cmd, "serve")) {
 // 契约 #3：壳生成 token 并通过 argv/env 传入；单独自测则自生成。
 var token = handshake.generateToken();
 if (token_hex) |h| {
 if (h.len != handshake.TOKEN_HEX_LEN) {
 out("token 长度必须是 {d} 个 hex 字符", .{handshake.TOKEN_HEX_LEN});
 std.process.exit(2);
 }
 @memcpy(&token.hex, h);
 } else {
 out("--token 未提供，已自生成（仅用于自测；生产必须由壳传入）", .{});
 }
 try http_server.run(gpa, token);
 return;
 }

 if (std.mem.eql(u8, cmd, "e1")) {
 out("E1: 并发 / 取消探针（线程 + 队列 + 原子取消）", .{});
 const r = try e1.probe(gpa);
 out(" produced={d} consumed={d} cancelled={}", .{ r.produced, r.consumed, r.cancelled });
 out(" 判据：取消后生产者停止、消费者被唤醒、无泄漏（GPA 已校验）", .{});
 return;
 }

 if (std.mem.eql(u8, cmd, "e4")) {
 out("E4: 内存所有权探针（200 轮 + 3 次压缩）", .{});
 const a = try e4.simulateArena(gpa, 200);
 out(" 策略 A（全 arena + 整体重建）：", .{});
 out(" peak_live={d} live_at_end={d} total_alloc={d} allocs={d} msgs={d} compactions={d}", .{
 a.peak_live, a.live_at_end, a.total_alloc, a.alloc_count, a.messages, a.compactions,
 });
 const c = try e4.simulateTurnArena(gpa, 200);
 out(" 策略 C（per-turn arena）：", .{});
 out(" peak_live={d} live_at_end={d} total_alloc={d} allocs={d} msgs={d} compactions={d}", .{
 c.peak_live, c.live_at_end, c.total_alloc, c.alloc_count, c.messages, c.compactions,
 });
 out(" 判据：peak_live 有界（<1MB）且 live_at_end=0；A 的分配次数应少于 C", .{});
 return;
 }

 if (std.mem.eql(u8, cmd, "e5")) {
 out("E5: 密码学与数据格式兼容（硬约束）", .{});
 out(" 1) 由既有实现侧生成向量（用 | 分隔，因为 enc:1: 自带冒号）：", .{});
 out(" System.out.println(home + \"|\" + host + \"|\" + ProviderSecretCrypto.encrypt(\"sk-test\") + \"|sk-test\");", .{});
 out(" 2) export SPIKE_ENC1_VECTOR='<home>|<hostname>|<enc:1:...>|<plaintext>'", .{});
 out(" 3) zig build test", .{});
 out(" ⚠️ 跑之前必须把 e5_crypto.zig 里的 APP_SECRET_PLACEHOLDER / SALT_PLACEHOLDER", .{});
 out(" 替换成既有实现里的真实常量，否则一定解不开。", .{});
 out(" 提示：即使不跑向量，PBKDF2 的 RFC 已知向量测试也会验证算法参数正确。", .{});
 return;
 }

 out("zig-m0 spike —— Zigent 内核的技术验证", .{});
 out("", .{});
 out(" --version 打印版本（桌面壳契约 #5）", .{});
 out(" serve [--token HEX] E3：本地 HTTP/SSE 服务 + 桌面壳交付契约 7 条", .{});
 out(" e1 E1：并发 / 取消探针", .{});
 out(" e4 E4：内存所有权探针", .{});
 out(" e5 E5：兼容性测试说明", .{});
 out("", .{});
 out("测试：zig build test / zig build test-tsan", .{});
 out("文档：../移植雷区.md、../README.md", .{});
}
