//! Executable SCRAM contracts: RFC 7677 vector, verifier interoperability,
//! authentication failures, replay rejection and malformed input bounds.
const std = @import("std");
const scram = @import("scram");
var assertions: usize = 0;
var fuzz_inputs: usize = 0;
const salt_b64 = "W22ZaJ0SNY7soEsUEjb6gQ==";
const nonce = "%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";
const first = "n,,n=user,r=rOprNGfwEbeRWgbNEkqO";
const challenge = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
const final = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=";
const signature = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=";
const native_verifier = "SCRAM-SHA-256$4096:W22ZaJ0SNY7soEsUEjb6gQ==$WG5d8oPm3OtcPnkdi4Uo7BkeZkBFzpcXkuLmtbsT4qY=:wfPLwcE6nTWhTAmQ7tl2KeoiWGPlZqQxSrmfPwDl2dU=";

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.ScramContractFailed;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn rejects(wanted: anyerror, result: anytype) !void {
    if (result) |_| return error.InvalidAuthenticationAccepted else |err| try check(err == wanted);
}
fn verifier() !scram.Verifier {
    var salt: [16]u8 = undefined;
    try std.base64.standard.Decoder.decode(&salt, salt_b64);
    return scram.Verifier.fromPassword("user", "pencil", &salt, 4096);
}

fn rfcVector() !void {
    const v = try verifier();
    var encoded: [512]u8 = undefined;
    try check(eq(try v.format(&encoded), native_verifier));
    const parsed = try scram.Verifier.parse("user", native_verifier);
    try check(eq(&parsed.stored_key, &v.stored_key));
    try check(eq(&parsed.server_key, &v.server_key));
    var server = try scram.Server.init(&parsed, nonce);
    server.setUsername("user");
    var output: [512]u8 = undefined;
    try check(eq(try server.start(first, &output), challenge));
    try check(server.state == .challenge);
    try check(eq(try server.finish(final, &output), signature));
    try check(server.state == .complete);
    try rejects(error.AuthenticationState, server.finish(final, &output));
    try rejects(error.AuthenticationState, server.start(first, &output));
}

fn clientFinal(v: *const scram.Verifier, password: []const u8, bare: []const u8, server_first: []const u8, channel: []const u8, combined_nonce: []const u8, extensions: []const u8, output: []u8) ![]const u8 {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var salted: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &salted);
    try std.crypto.pwhash.pbkdf2(&salted, password, v.salt[0..v.salt_len], v.iterations, Hmac);
    var key: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    Hmac.create(&key, "Client Key", &salted);
    var prefix_buffer: [1024]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buffer, "c={s},r={s}{s}", .{ channel, combined_nonce, extensions });
    var auth_buffer: [2048]u8 = undefined;
    const auth = try std.fmt.bufPrint(&auth_buffer, "{s},{s},{s}", .{ bare, server_first, prefix });
    var signature_bytes: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &signature_bytes);
    Hmac.create(&signature_bytes, auth, &v.stored_key);
    var proof: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &proof);
    for (&proof, key, signature_bytes) |*p, k, s| p.* = k ^ s;
    var encoded: [44]u8 = undefined;
    return std.fmt.bufPrint(output, "{s},p={s}", .{ prefix, std.base64.standard.Encoder.encode(&encoded, &proof) });
}

fn positiveVariants() !void {
    const v = try verifier();
    const cases = [_][]const u8{
        "n,,n=,r=client-nonce",
        "n,,n=ignored-name,r=client-nonce",
        "y,,n=user,r=client-nonce",
        "n,,n=escaped=2Cname=3D,r=client-nonce",
        "y,,n=user,r=client-nonce,x=signed-client-first-extension",
    };
    for (cases) |source| {
        var s = try scram.Server.init(&v, nonce);
        s.setUsername("user");
        var challenge_buffer: [512]u8 = undefined;
        const server_first = try s.start(source, &challenge_buffer);
        var final_buffer: [1024]u8 = undefined;
        const response = try clientFinal(&v, "pencil", source[3..], server_first, if (source[0] == 'y') "eSws" else "biws", s.combined_nonce[0..s.combined_nonce_len], ",x=signed-client-final-extension", &final_buffer);
        var output: [512]u8 = undefined;
        try check((try s.finish(response, &output)).len == 46 and s.state == .complete);
    }
    // Maximum accepted nonce and salt sizes still fit the bounded transcript.
    const long_salt: [64]u8 = @splat(0x5a);
    const long_verifier = try scram.Verifier.fromPassword("user", "pencil", &long_salt, 4096);
    const server_nonce: [128]u8 = @splat('S');
    const client_nonce: [256]u8 = @splat('C');
    var first_buffer: [512]u8 = undefined;
    const source = try std.fmt.bufPrint(&first_buffer, "n,,n=user,r={s}", .{client_nonce});
    var server = try scram.Server.init(&long_verifier, &server_nonce);
    var challenge_buffer: [512]u8 = undefined;
    const server_first = try server.start(source, &challenge_buffer);
    var final_buffer: [1024]u8 = undefined;
    const response = try clientFinal(&long_verifier, "pencil", source[3..], server_first, "biws", server.combined_nonce[0..server.combined_nonce_len], "", &final_buffer);
    var output: [512]u8 = undefined;
    try check((try server.finish(response, &output)).len == 46 and server.state == .complete);
}

fn credentialFailures() !void {
    const v = try verifier();
    var output: [512]u8 = undefined;
    var wrong_user = try scram.Server.init(&v, nonce);
    wrong_user.setUsername("attacker");
    try check(eq(try wrong_user.start(first, &output), challenge));
    try rejects(error.AuthenticationFailed, wrong_user.finish(final, &output));
    try check(wrong_user.state == .failed);
    var bad_proof: [final.len]u8 = final.*;
    for (final.len - 44..final.len - 1) |i| {
        var server = try scram.Server.init(&v, nonce);
        _ = try server.start(first, &output);
        bad_proof = final.*;
        bad_proof[i] = if (bad_proof[i] == 'A') 'B' else 'A';
        try rejects(error.AuthenticationFailed, server.finish(&bad_proof, &output));
        try check(server.state == .failed);
    }
    var replay = try scram.Server.init(&v, "fresh-unpredictable-nonce-for-next-connection");
    _ = try replay.start(first, &output);
    try rejects(error.AuthenticationFailed, replay.finish(final, &output));
    // PostgreSQL authenticates the startup name, not n= in the SASL message.
    var ignored_name = try scram.Server.init(&v, nonce);
    ignored_name.setUsername("user");
    _ = try ignored_name.start("n,,n=another-user,r=rOprNGfwEbeRWgbNEkqO", &output);
    try rejects(error.AuthenticationFailed, ignored_name.finish(final, &output));
    // It remains part of AuthMessage, so an unauthenticated name cannot be edited.
    var fail_closed = try scram.Server.init(&v, nonce);
    try rejects(error.AuthenticationFailed, fail_closed.start("n,,m=required,n=user,r=nonce", &output));
    try rejects(error.AuthenticationState, fail_closed.start(first, &output));
    try rejects(error.AuthenticationState, fail_closed.finish(final, &output));
}

fn invalidConfiguration() !void {
    const v = try verifier();
    for ([_][]const u8{ "", "short", "contains,comma-and-enough-characters", "contains space-and-enough-characters", "contains\x00zero-and-enough-characters" }) |n| try rejects(error.InvalidNonce, scram.Server.init(&v, n));
    const salt = "1234567890abcdef";
    try rejects(error.InvalidVerifier, scram.Verifier.fromPassword("", "pass", salt, 4096));
    try rejects(error.InvalidVerifier, scram.Verifier.fromPassword("user", "", salt, 4096));
    try rejects(error.InvalidVerifier, scram.Verifier.fromPassword("user", "pass", "short", 4096));
    try rejects(error.InvalidVerifier, scram.Verifier.fromPassword("user", "pass", salt, 4095));
    try rejects(error.InvalidVerifier, scram.Verifier.fromPassword("user", "pass", salt, 10_000_001));
    try rejects(error.PasswordNormalizationUnsupported, scram.Verifier.fromPassword("user", "p\xc3\xa4ss", salt, 4096));
    try rejects(error.PasswordNormalizationUnsupported, scram.Verifier.fromPassword("user", "p\x01ss", salt, 4096));
    for ([_][]const u8{ "", "SCRAM-SHA-1$4096:salt$key:key", "SCRAM-SHA-256$0:salt$key:key", "SCRAM-SHA-256$999999999999999999999999999999:salt$key:key", "SCRAM-SHA-256$4096:salt$key:key", "SCRAM-SHA-256$4096:W22ZaJ0SNY7soEsUEjb6gQ==$short:short" }) |source| try rejects(error.InvalidVerifier, scram.Verifier.parse("user", source));
    var tiny: [4]u8 = undefined;
    try rejects(error.BufferTooSmall, v.format(&tiny));
    var s = try scram.Server.init(&v, nonce);
    try rejects(error.BufferTooSmall, s.start(first, &tiny));
    try check(s.state == .initial);
    var output: [512]u8 = undefined;
    _ = try s.start(first, &output);
    try rejects(error.BufferTooSmall, s.finish(final, &tiny));
    try check(s.state == .challenge);
    try check(eq(try s.finish(final, &output), signature));
}

fn malformed() !void {
    const v = try verifier();
    var output: [512]u8 = undefined;
    for ([_][]const u8{ "", "n,", "n,,", "p=tls-server-end-point,,n=user,r=nonce", "n,a=admin,n=user,r=nonce", "n,,r=nonce,n=user", "n,,n=user", "n,,n=user,r=", "n,,n=user,r=space here", "n,,n=user,r=nonce,r=again", "n,,n=user,r=nonce,", "n,,n=user=2c,r=nonce", "n,,n=user=,r=nonce", "n,,n=user,r=nonce,m=required", "n,,n=user,r=nonce,n=again" }) |source| {
        var s = try scram.Server.init(&v, nonce);
        try rejects(error.AuthenticationFailed, s.start(source, &output));
        try check(s.state == .failed);
    }
    for ([_][]const u8{ "", "c=biws,r=nonce", "c=biws,r=nonce,p=wrong", "c=biws,r=nonce,p=", "c=biws,r=nonce,p=AA==", "r=nonce,c=biws,p=wrong", "c=cD10bHMtc2VydmVyLWVuZC1wb2ludCws,r=nonce,p=wrong", "c=biws,r=nonce,p=wrong,m=required", "c=biws,r=nonce,p=wrong,p=again" }) |source| {
        var s = try scram.Server.init(&v, nonce);
        _ = try s.start(first, &output);
        try rejects(error.AuthenticationFailed, s.finish(source, &output));
        try check(s.state == .failed);
    }
    var too_long: [2048]u8 = @splat('a');
    var a = try scram.Server.init(&v, nonce);
    try rejects(error.AuthenticationFailed, a.start(&too_long, &output));
    var b = try scram.Server.init(&v, nonce);
    _ = try b.start(first, &output);
    try rejects(error.AuthenticationFailed, b.finish(&too_long, &output));
}

fn fuzz() !void {
    const v = try verifier();
    var seed: u32 = 0xb08e47ac;
    var input: [1100]u8 = undefined;
    var output: [512]u8 = undefined;
    for (0..8192) |case| {
        const len = case % input.len;
        for (input[0..len]) |*c| {
            seed = seed *% 1664525 +% 1013904223;
            c.* = @truncate(seed >> 24);
        }
        var a = try scram.Server.init(&v, nonce);
        if (a.start(input[0..len], &output)) |message| {
            try check(message.len <= output.len and a.state == .challenge);
        } else |_| try check(a.state == .failed);
        var b = try scram.Server.init(&v, nonce);
        _ = try b.start(first, &output);
        try rejects(error.AuthenticationFailed, b.finish(input[0..len], &output));
        try check(b.state == .failed);
        fuzz_inputs += 1;
    }
}

pub fn main(init: std.process.Init) !void {
    try rfcVector();
    try positiveVariants();
    try credentialFailures();
    try invalidConfiguration();
    try malformed();
    try fuzz();
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"scram\",\"pass\":true,\"assertions\":{d},\"fuzz_inputs\":{d},\"server_bytes\":{d}}}\n", .{ assertions, fuzz_inputs, @sizeOf(scram.Server) });
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
