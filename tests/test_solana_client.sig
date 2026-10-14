const std = @import("std");
const client = @import("solana_client");
const json = @import("solana_rpc_json");
const rpc = @import("solana_rpc");
const base58 = @import("solana_base58");
const vector = @import("solana_client_vector.sig");
var assertions: usize = 0;
fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.ClientContractFailed;
}
fn rejects(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.InvalidAccepted else |actual| try check(actual == expected);
}
const Mock = struct {
    pub var response: []const u8 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}";
    pub fn post(_: []const u8, out: []u8) ![]const u8 {
        @memcpy(out[0..response.len], response);
        return out[0..response.len];
    }
};
pub fn main(init: std.process.Init) !void {
    var seed: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&seed, "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    const wallet = try client.Wallet.fromSeed(seed);
    var expected_public: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_public, "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    const public = wallet.publicKey();
    try check(std.mem.eql(u8, &public, &expected_public));
    var packet: [1232]u8 = undefined;
    var expected: [1232]u8 = undefined;
    const golden = try std.fmt.hexToBytes(&expected, vector.packet_hex);
    const length = try wallet.transaction(@splat(7), @splat(8), &.{ .{ .key = public, .writable = true }, .{ .key = @splat(9), .writable = true } }, "hello", &packet);
    try check(std.mem.eql(u8, packet[0..length], golden));
    var small: [8]u8 = @splat(17);
    try rejects(error.Capacity, wallet.transaction(@splat(7), @splat(8), &.{}, "hello", &small));
    try check(small[0] == 17);
    try rejects(error.DuplicateAccount, wallet.transaction(@splat(7), @splat(8), &.{ .{ .key = @splat(9), .writable = true }, .{ .key = @splat(9), .writable = false } }, "hello", &packet));
    var program: [32]u8 = undefined;
    var owner: [32]u8 = undefined;
    var pda: [32]u8 = undefined;
    var expected_pda: [32]u8 = undefined;
    try base58.decodeKey("7ya9kk85WktA97Aq3LqWcauDcr4LdjVXt6hZX2icKtRV", &program);
    _ = try std.fmt.hexToBytes(&owner, "abf2ec510f05d3c74cef8647ae7a7aba8602e561de8f8c1c97a97f3b832c23d3");
    const world = [_]u8{ 0x4e, 0x49, 0x52, 0x47, 0x45, 0x4e, 0x49, 0x4d };
    _ = try client.findAddress(&.{ "mg-player-v1", &world, &owner }, &program, &pda);
    try base58.decodeKey("73qzQXQXFsoxdVQ7PdNn5Py8ghige2uFKQy8U14AapRk", &expected_pda);
    try check(std.mem.eql(u8, &pda, &expected_pda));
    try check(!client.onCurve(&pda));
    try check(client.onCurve(&public));
    _ = try client.findAddress(&.{ "mg-node-v1", &world, &.{ 0, 0 } }, &program, &pda);
    try base58.decodeKey("DhrqHRHGmUAFMWL4ZpG16R2nto3baoQ6attEWu4PavUN", &expected_pda);
    try check(std.mem.eql(u8, &pda, &expected_pda));
    try rejects(error.SeedTooLong, client.findAddress(&.{"x" ** 33}, &program, &pda));
    const good = "{\"result\":{\"value\":[null,{\"err\":null,\"confirmationStatus\":\"finalized\"}]},\"id\":1}";
    try json.validate(good);
    const value = try json.field(try json.field(good, "result"), "value");
    try check(std.mem.eql(u8, try json.item(value, 0), "null"));
    try check(std.mem.eql(u8, try json.string(try json.field(try json.item(value, 1), "confirmationStatus")), "finalized"));
    for ([_][]const u8{ "{\"id\":1 \"result\":2}", "[1,]", "{\"id\":01}", "{\"id\":1} garbage", "{\"id\":\"\\q\"}", "[1}", "{\"id\":1," }) |bad| try rejects(error.InvalidJson, json.validate(bad));
    try rejects(error.DuplicateField, json.field("{\"id\":1,\"id\":2}", "id"));
    var buffers: rpc.Buffers = .{};
    const Rpc = rpc.API(Mock);
    try check(std.mem.eql(u8, try Rpc.call(&buffers, "getHealth", "[]"), "null"));
    Mock.response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":true}";
    try rejects(error.InvalidResponse, Rpc.call(&buffers, "getHealth", "[]"));
    Mock.response = "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-1}}";
    try rejects(error.RpcRejected, Rpc.call(&buffers, "getHealth", "[]"));
    const signature: [64]u8 = @splat(4);
    buffers.next_id = 0;
    Mock.response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":[null]}}";
    try check(try Rpc.status(&buffers, &signature) == .unknown);
    buffers.next_id = 0;
    Mock.response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":[{\"err\":{\"Custom\":5},\"confirmationStatus\":\"confirmed\"}]}}";
    try check(try Rpc.status(&buffers, &signature) == .pending);
    buffers.next_id = 0;
    Mock.response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":[{\"err\":null,\"confirmationStatus\":\"finalized\"}]}}";
    try check(try Rpc.status(&buffers, &signature) == .finalized);
    buffers.next_id = 0;
    Mock.response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":[{\"err\":{\"Custom\":5},\"confirmationStatus\":\"finalized\"}]}}";
    try check(try Rpc.status(&buffers, &signature) == .failed);
    buffers.next_id = 0;
    Mock.response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32002}}";
    try rejects(error.PreflightRejected, Rpc.call(&buffers, "sendTransaction", "[]"));
    try rejects(error.InvalidJson, json.number("01"));
    var out: [96]u8 = undefined;
    const message = try std.fmt.bufPrint(&out, "Solana client PASS: {d} assertions\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, message);
}
