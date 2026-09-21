//! 测试聚合入口 —— `zig build test` 从这里跑所有纯逻辑测试。
//!
//! 这些测试**不需要网络、不需要真实 provider**，因此可以在 CI 里跑。
//! 它们直接编码了移植雷区.md 里的契约，所以：
//! - 测试通过 = 契约在代码里成立；
//! - 将来 Zig 版本升级导致 API 变化时，这里的失败会**第一时间**暴露问题。
//!
//! 需要外部条件的测试（E5 的既有实现向量）在缺少环境变量时自动跳过。

test {
 _ = @import("sse.zig"); // A. SSE 读入侧 7 条规则
 _ = @import("sse_writer.zig"); // 写出侧 3 条规则 + 读写对称
 _ = @import("toolcalls.zig"); // B. 三家 tool_call 拼接语义
 _ = @import("handshake.zig"); // 桌面壳交付契约可测部分
 _ = @import("e1_io.zig"); // E1 取消语义
 _ = @import("e4_memory.zig"); // E4 内存所有权
 _ = @import("e5_crypto.zig"); // E5 密码学格式
 _ = @import("width.zig"); // 显示宽度（本期非核心，保留作 CLI --print 参考）
}
