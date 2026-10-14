//! Caller-buffer JSON-RPC client. No transport, threads or implicit retries.
const std = @import("std");
const json = @import("solana_rpc_json");
const base58 = @import("solana_base58");
pub const Error = error{ Capacity, RpcRejected, PreflightRejected, InvalidResponse, InvalidEncoding };
pub const Status = enum { unknown, pending, finalized, failed };
pub const Blockhash = struct { key: [32]u8, last_valid_height: u64 };
pub const Account = struct { slot: u64, owner: [32]u8, lamports: u64, executable: bool, data: []const u8 };
pub const Buffers = struct { request: [4096]u8 = undefined, response: [16384]u8 = undefined, encoded: [1664]u8 = undefined, next_id: u64 = 0 };
fn decodeAccount(value: []const u8, slot: u64, output: []u8) !?Account {
    if (std.mem.eql(u8, value, "null")) return null;
    var owner: [32]u8 = undefined;
    base58.decodeKey(try json.string(try json.field(value, "owner")), &owner) catch return error.InvalidEncoding;
    const data = try json.field(value, "data");
    if (!std.mem.eql(u8, try json.string(try json.item(data, 1)), "base64")) return error.InvalidEncoding;
    const encoded = try json.string(try json.item(data, 0));
    const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidEncoding;
    if (size > output.len) return error.Capacity;
    std.base64.standard.Decoder.decode(output[0..size], encoded) catch return error.InvalidEncoding;
    const executable = try json.field(value, "executable");
    if (!std.mem.eql(u8, executable, "true") and !std.mem.eql(u8, executable, "false")) return error.InvalidResponse;
    return .{ .slot = slot, .owner = owner, .lamports = try json.number(try json.field(value, "lamports")), .executable = std.mem.eql(u8, executable, "true"), .data = output[0..size] };
}
pub fn API(comptime Transport: type) type {
    return struct {
        pub fn call(buffers: *Buffers, method: []const u8, params: []const u8) ![]const u8 {
            buffers.next_id += 1;
            const request = std.fmt.bufPrint(&buffers.request, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ buffers.next_id, method, params }) catch return error.Capacity;
            const response = try Transport.post(request, &buffers.response);
            if (!std.mem.eql(u8, try json.string(try json.field(response, "jsonrpc")), "2.0") or try json.number(try json.field(response, "id")) != buffers.next_id) return error.InvalidResponse;
            const rpc_error = json.field(response, "error") catch |err| switch (err) {
                error.MissingField => "null",
                else => return error.InvalidResponse,
            };
            if (!std.mem.eql(u8, rpc_error, "null")) {
                const code = json.field(rpc_error, "code") catch return error.InvalidResponse;
                if (std.mem.eql(u8, method, "sendTransaction") and std.mem.eql(u8, code, "-32002")) return error.PreflightRejected;
                return error.RpcRejected;
            }
            return json.field(response, "result") catch return error.InvalidResponse;
        }
        pub fn genesis(buffers: *Buffers, output: *[32]u8) !void {
            base58.decodeKey(try json.string(try call(buffers, "getGenesisHash", "[]")), output) catch return error.InvalidEncoding;
        }
        pub fn latest(buffers: *Buffers) !Blockhash {
            const value = try json.field(try call(buffers, "getLatestBlockhash", "[{\"commitment\":\"confirmed\"}]"), "value");
            var result: Blockhash = undefined;
            base58.decodeKey(try json.string(try json.field(value, "blockhash")), &result.key) catch return error.InvalidEncoding;
            result.last_valid_height = try json.number(try json.field(value, "lastValidBlockHeight"));
            return result;
        }
        pub fn submit(buffers: *Buffers, packet: []const u8, expected_signature: *const [64]u8) !void {
            const size = std.base64.standard.Encoder.calcSize(packet.len);
            if (size > buffers.encoded.len) return error.Capacity;
            const encoded = std.base64.standard.Encoder.encode(&buffers.encoded, packet);
            var params: [2048]u8 = undefined;
            const args = std.fmt.bufPrint(&params, "[\"{s}\",{{\"encoding\":\"base64\",\"preflightCommitment\":\"confirmed\",\"maxRetries\":3}}]", .{encoded}) catch return error.Capacity;
            const result = try json.string(try call(buffers, "sendTransaction", args));
            var decoded: [64]u8 = undefined;
            const len = base58.decode(result, &decoded) catch return error.InvalidEncoding;
            if (len != 64 or !std.mem.eql(u8, &decoded, expected_signature)) return error.InvalidResponse;
        }
        pub fn status(buffers: *Buffers, signature: *const [64]u8) !Status {
            var key: [88]u8 = undefined;
            const len = base58.encode(signature, &key) catch return error.Capacity;
            var params: [192]u8 = undefined;
            const args = std.fmt.bufPrint(&params, "[[\"{s}\"],{{\"searchTransactionHistory\":true}}]", .{key[0..len]}) catch return error.Capacity;
            const value = try json.item(try json.field(try call(buffers, "getSignatureStatuses", args), "value"), 0);
            if (std.mem.eql(u8, value, "null")) return .unknown;
            const error_value = try json.field(value, "err");
            const confirmation = try json.string(try json.field(value, "confirmationStatus"));
            if (std.mem.eql(u8, confirmation, "finalized")) return if (std.mem.eql(u8, error_value, "null")) .finalized else .failed;
            if (!std.mem.eql(u8, confirmation, "processed") and !std.mem.eql(u8, confirmation, "confirmed")) return error.InvalidResponse;
            return .pending;
        }
        pub fn height(buffers: *Buffers) !u64 {
            return json.number(try call(buffers, "getBlockHeight", "[{\"commitment\":\"finalized\"}]"));
        }
        pub fn balance(buffers: *Buffers, public_key: *const [32]u8) !u64 {
            var key: [44]u8 = undefined;
            const len = base58.encodeKey(public_key, &key);
            var params: [128]u8 = undefined;
            const args = std.fmt.bufPrint(&params, "[\"{s}\",{{\"commitment\":\"finalized\"}}]", .{key[0..len]}) catch return error.Capacity;
            return json.number(try json.field(try call(buffers, "getBalance", args), "value"));
        }
        pub fn account(buffers: *Buffers, key_bytes: *const [32]u8, output: []u8) !?Account {
            var key: [44]u8 = undefined;
            const len = base58.encodeKey(key_bytes, &key);
            var params: [160]u8 = undefined;
            const args = std.fmt.bufPrint(&params, "[\"{s}\",{{\"encoding\":\"base64\",\"commitment\":\"finalized\"}}]", .{key[0..len]}) catch return error.Capacity;
            const result = try call(buffers, "getAccountInfo", args);
            const value = try json.field(result, "value");
            if (std.mem.eql(u8, value, "null")) return null;
            var owner: [32]u8 = undefined;
            base58.decodeKey(try json.string(try json.field(value, "owner")), &owner) catch return error.InvalidEncoding;
            const data = try json.field(value, "data");
            if (!std.mem.eql(u8, try json.string(try json.item(data, 1)), "base64")) return error.InvalidEncoding;
            const encoded = try json.string(try json.item(data, 0));
            const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidEncoding;
            if (size > output.len) return error.Capacity;
            std.base64.standard.Decoder.decode(output[0..size], encoded) catch return error.InvalidEncoding;
            const executable = try json.field(value, "executable");
            if (!std.mem.eql(u8, executable, "true") and !std.mem.eql(u8, executable, "false")) return error.InvalidResponse;
            return .{ .slot = try json.number(try json.field(try json.field(result, "context"), "slot")), .owner = owner, .lamports = try json.number(try json.field(value, "lamports")), .executable = std.mem.eql(u8, executable, "true"), .data = output[0..size] };
        }
        /// Every account comes from one finalized bank context; no mixed-slot view.
        pub fn accounts(buffers: *Buffers, keys: []const [32]u8, storage: []const []u8, output: []?Account) !u64 {
            if (keys.len > 8 or storage.len != keys.len or output.len != keys.len) return error.Capacity;
            var params: [1024]u8 = undefined;
            params[0] = '[';
            params[1] = '[';
            var pos: usize = 2;
            for (keys, 0..) |key, index| {
                var text: [44]u8 = undefined;
                const len = base58.encodeKey(&key, &text);
                const value = std.fmt.bufPrint(params[pos..], "{s}\"{s}\"", .{ if (index == 0) "" else ",", text[0..len] }) catch return error.Capacity;
                pos += value.len;
            }
            const suffix = "] ,{\"encoding\":\"base64\",\"commitment\":\"finalized\"}]";
            if (suffix.len > params.len - pos) return error.Capacity;
            @memcpy(params[pos..][0..suffix.len], suffix);
            pos += suffix.len;
            const result = try call(buffers, "getMultipleAccounts", params[0..pos]);
            const slot = try json.number(try json.field(try json.field(result, "context"), "slot"));
            const values = try json.field(result, "value");
            for (storage, 0..) |bytes, index| output[index] = try decodeAccount(try json.item(values, index), slot, bytes);
            if (json.item(values, keys.len)) |_| return error.InvalidResponse else |err| {
                if (err != error.MissingField) return error.InvalidResponse;
            }
            return slot;
        }
        pub fn airdrop(buffers: *Buffers, key_bytes: *const [32]u8, signature: *[64]u8) !void {
            var key: [44]u8 = undefined;
            const len = base58.encodeKey(key_bytes, &key);
            var params: [128]u8 = undefined;
            const args = std.fmt.bufPrint(&params, "[\"{s}\",2000000000]", .{key[0..len]}) catch return error.Capacity;
            const result = try json.string(try call(buffers, "requestAirdrop", args));
            if (try base58.decode(result, signature) != 64) return error.InvalidEncoding;
        }
    };
}
