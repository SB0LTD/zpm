const std = @import("std");
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP384Sha384;
pub const SIG_LEN = 96;
pub const SCALAR_LEN = 48;
pub const PUBKEY_UNCOMPRESSED_LEN = 97;
pub fn verify(public_key_xy: *const [96]u8, digest: *const [48]u8, signature: *const [96]u8) bool {
    var sec1: [97]u8 = undefined; sec1[0] = 4; @memcpy(sec1[1..], public_key_xy);
    const key = Ecdsa.PublicKey.fromSec1(&sec1) catch return false;
    Ecdsa.Signature.fromBytes(signature.*).verifyPrehashed(digest.*, key) catch return false;
    return true;
}
pub fn sign(private_key: *const [48]u8, digest: *const [48]u8, out: *[96]u8) bool {
    const secret = Ecdsa.SecretKey.fromBytes(private_key.*) catch return false;
    const pair = Ecdsa.KeyPair.fromSecretKey(secret) catch return false;
    out.* = (pair.signPrehashed(digest.*, null) catch return false).toBytes(); return true;
}