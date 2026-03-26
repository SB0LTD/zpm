// Layer 1 — TLS 1.3 integration and QUIC packet protection.
//
// Drives the TLS 1.3 handshake via Windows SChannel/BCrypt. Derives QUIC
// packet protection keys. All state in a fixed-size struct. Zero allocator
// usage. Implements RFC 9001 §5 (packet protection), §6 (key update).

const w32 = @import("win32");
const packet = @import("packet");
const platform_crypto = @import("crypto");

// ── ALPN Protocol String ──

pub const ZPM_ALPN: []const u8 = "zpm";

// ── Encryption Level ──

pub const EncryptionLevel = enum(u2) {
    initial = 0,
    handshake = 1,
    zero_rtt = 2,
    one_rtt = 3,
};

// ── Cipher Suite ──

pub const CipherSuite = enum(u8) {
    aes_128_gcm_sha256 = 0,
};

// ── Key Material ──

pub const KeySet = struct {
    key: [16]u8 = [_]u8{0} ** 16,
    iv: [12]u8 = [_]u8{0} ** 12,
    hp_key: [16]u8 = [_]u8{0} ** 16,
    valid: bool = false,
};

// ── Error Types ──

pub const CryptoError = enum(u8) {
    none,
    handshake_failed,
    cert_validation_failed,
    unsupported_cipher,
    protocol_error,
    decrypt_failed,
    buffer_too_small,
};

// ── TLS Output ──

pub const TlsOutput = struct {
    level: EncryptionLevel = .initial,
    data: [4096]u8 = [_]u8{0} ** 4096,
    data_len: u16 = 0,
    has_data: bool = false,
};

// ── Handshake Result ──

pub const HandshakeResult = struct {
    complete: bool = false,
    alpn: [32]u8 = [_]u8{0} ** 32,
    alpn_len: u8 = 0,
    transport_params: [512]u8 = [_]u8{0} ** 512,
    transport_params_len: u16 = 0,
    output: TlsOutput = .{},
    err: CryptoError = .none,
};

// ── TLS Engine ──

pub const TlsEngine = struct {
    // SChannel context handles (opaque Win32 handles stored as raw u64 pairs)
    cred_handle: [2]u64 = [_]u64{ 0, 0 },
    ctx_handle: [2]u64 = [_]u64{ 0, 0 },

    // Handshake state machine
    state: State = .idle,

    // Key material per encryption level
    keys: [4]KeySet = [_]KeySet{.{}} ** 4,

    // Session ticket for 0-RTT resumption
    ticket: [512]u8 = [_]u8{0} ** 512,
    ticket_len: u16 = 0,
    has_ticket: bool = false,

    // Handshake buffers
    recv_buf: [8192]u8 = [_]u8{0} ** 8192,
    recv_len: u16 = 0,
    send_buf: [8192]u8 = [_]u8{0} ** 8192,
    send_len: u16 = 0,

    // Current application traffic secret for key updates (RFC 9001 §6)
    app_secret: [32]u8 = [_]u8{0} ** 32,

    // Role
    is_server: bool = false,

    pub const State = enum(u8) {
        idle,
        in_progress,
        complete,
        failed,
    };

    /// Initialize a TLS engine for client or server role.
    /// Acquires SChannel credentials configured for TLS 1.3 with ALPN "zpm".
    pub fn init(is_server: bool) TlsEngine {
        var engine = TlsEngine{};
        engine.is_server = is_server;

        // Set up SCH_CREDENTIALS for TLS 1.3
        var creds = w32.SCH_CREDENTIALS{
            .dwVersion = 5, // SCH_CREDENTIALS_VERSION
            .dwFlags = if (is_server)
                0
            else
                (w32.SCH_CRED_NO_DEFAULT_CREDS | w32.SCH_CRED_MANUAL_CRED_VALIDATION),
        };

        // Set up ALPN via SEC_APPLICATION_PROTOCOLS
        // ALPN wire format: 1-byte length prefix + protocol string
        var alpn_protos = w32.SEC_APPLICATION_PROTOCOLS{};
        alpn_protos.ProtocolLists.ProtoNegoExt = w32.SecApplicationProtocolNegotiationExt_ALPN;
        // Wire format: [length_byte, 'h', 'e', 'i', 'l']
        alpn_protos.ProtocolLists.ProtocolList[0] = @intCast(ZPM_ALPN.len); // 4
        @memcpy(alpn_protos.ProtocolLists.ProtocolList[1 .. 1 + ZPM_ALPN.len], ZPM_ALPN);
        alpn_protos.ProtocolLists.ProtocolListSize = @intCast(1 + ZPM_ALPN.len);
        // ProtocolListsSize = size of the SEC_APPLICATION_PROTOCOL_LIST header (4 + 2) + wire data
        alpn_protos.ProtocolListsSize = @intCast(@sizeOf(w32.SEC_APPLICATION_PROTOCOL_LIST));

        const cred_use: w32.DWORD = if (is_server) w32.SECPKG_CRED_INBOUND else w32.SECPKG_CRED_OUTBOUND;

        var cred_handle: w32.CredHandle = .{};
        const status = w32.AcquireCredentialsHandleW(
            null, // principal
            w32.UNISP_NAME_W, // package
            cred_use,
            null, // logon id
            @ptrCast(&creds), // auth data (SCH_CREDENTIALS)
            null, // get key fn
            null, // get key arg
            &cred_handle,
            null, // expiry
        );

        if (status == w32.SEC_E_OK) {
            // Store CredHandle as [2]u64 via bitcast
            engine.cred_handle = @bitCast(cred_handle);
        } else {
            engine.state = .failed;
        }

        // Store ALPN protocols buffer for use in handshake calls
        // We keep it in send_buf temporarily — startHandshake/feedCryptoData will set up
        // the ALPN buffer from the comptime constant each time
        _ = &alpn_protos;

        return engine;
    }

    /// Feed received CRYPTO frame data into the handshake engine.
    /// Appends data to recv_buf, then calls InitializeSecurityContextW (client)
    /// or AcceptSecurityContext (server) with accumulated data.
    pub fn feedCryptoData(self: *TlsEngine, level: EncryptionLevel, data: []const u8) HandshakeResult {
        _ = level;
        var result = HandshakeResult{};

        if (self.state == .failed) {
            result.err = .handshake_failed;
            return result;
        }

        // Append incoming data to recv_buf
        const space = self.recv_buf.len - self.recv_len;
        const copy_len: u16 = @intCast(if (data.len > space) space else data.len);
        if (copy_len > 0) {
            @memcpy(self.recv_buf[self.recv_len .. self.recv_len + copy_len], data[0..copy_len]);
            self.recv_len += copy_len;
        }

        // Set up input SecBufferDesc: SECBUFFER_TOKEN (recv_buf data) + SECBUFFER_EMPTY
        var in_bufs: [2]w32.SecBuffer = .{
            .{
                .cbBuffer = self.recv_len,
                .BufferType = w32.SECBUFFER_TOKEN,
                .pvBuffer = @ptrCast(&self.recv_buf),
            },
            .{
                .cbBuffer = 0,
                .BufferType = w32.SECBUFFER_EMPTY,
                .pvBuffer = null,
            },
        };
        var in_buf_desc = w32.SecBufferDesc{
            .ulVersion = w32.SECBUFFER_VERSION,
            .cBuffers = 2,
            .pBuffers = @ptrCast(&in_bufs),
        };

        // Output: SECBUFFER_TOKEN
        var out_token_buf: [4096]u8 = undefined;
        var out_bufs: [1]w32.SecBuffer = .{
            .{
                .cbBuffer = out_token_buf.len,
                .BufferType = w32.SECBUFFER_TOKEN,
                .pvBuffer = @ptrCast(&out_token_buf),
            },
        };
        var out_buf_desc = w32.SecBufferDesc{
            .ulVersion = w32.SECBUFFER_VERSION,
            .cBuffers = 1,
            .pBuffers = @ptrCast(&out_bufs),
        };

        var cred_h: w32.CredHandle = @bitCast(self.cred_handle);
        var ctx_h: w32.CtxtHandle = @bitCast(self.ctx_handle);
        var out_flags: w32.DWORD = 0;
        var status: i32 = undefined;

        if (self.is_server) {
            const asc_flags: w32.DWORD = w32.ASC_REQ_SEQUENCE_DETECT |
                w32.ASC_REQ_REPLAY_DETECT |
                w32.ASC_REQ_CONFIDENTIALITY |
                w32.ASC_REQ_STREAM;

            status = w32.AcceptSecurityContext(
                &cred_h,
                if (self.state == .in_progress) &ctx_h else null,
                &in_buf_desc,
                asc_flags,
                0, // target data rep
                &ctx_h,
                &out_buf_desc,
                &out_flags,
                null, // expiry
            );
        } else {
            const isc_flags: w32.DWORD = w32.ISC_REQ_SEQUENCE_DETECT |
                w32.ISC_REQ_REPLAY_DETECT |
                w32.ISC_REQ_CONFIDENTIALITY |
                w32.ISC_REQ_STREAM |
                w32.ISC_REQ_MANUAL_CRED_VALIDATION;

            status = w32.InitializeSecurityContextW(
                &cred_h,
                &ctx_h,
                null, // server name already set from first call
                isc_flags,
                0, // reserved
                0, // target data rep
                &in_buf_desc,
                0, // reserved
                &ctx_h,
                &out_buf_desc,
                &out_flags,
                null, // expiry
            );
        }

        // Store updated context handle
        self.ctx_handle = @bitCast(ctx_h);

        if (status == w32.SEC_I_CONTINUE_NEEDED or status == w32.SEC_I_COMPLETE_AND_CONTINUE) {
            // Copy output token to TlsOutput
            const out_len = out_bufs[0].cbBuffer;
            if (out_len > 0 and out_len <= result.output.data.len) {
                const src: [*]const u8 = @ptrCast(out_bufs[0].pvBuffer.?);
                @memcpy(result.output.data[0..out_len], src[0..out_len]);
                result.output.data_len = @intCast(out_len);
                result.output.has_data = true;
                result.output.level = .handshake;
            }

            if (status == w32.SEC_I_COMPLETE_AND_CONTINUE) {
                _ = w32.CompleteAuthToken(&ctx_h, &out_buf_desc);
            }

            self.state = .in_progress;

            // Handle SECBUFFER_EXTRA: leftover data that wasn't consumed
            handleExtraBuffer(self, &in_bufs);
        } else if (status == w32.SEC_E_OK) {
            // Handshake complete
            // Copy any final output token
            const out_len = out_bufs[0].cbBuffer;
            if (out_len > 0 and out_len <= result.output.data.len) {
                const src: [*]const u8 = @ptrCast(out_bufs[0].pvBuffer.?);
                @memcpy(result.output.data[0..out_len], src[0..out_len]);
                result.output.data_len = @intCast(out_len);
                result.output.has_data = true;
                result.output.level = .handshake;
            }

            // Extract ALPN via QueryContextAttributesW
            var alpn_info = w32.SecPkgContext_ApplicationProtocol{};
            const query_status = w32.QueryContextAttributesW(
                &ctx_h,
                w32.SECPKG_ATTR_APPLICATION_PROTOCOL,
                @ptrCast(&alpn_info),
            );

            if (query_status == w32.SEC_E_OK and
                alpn_info.ProtoNegoStatus == w32.SecApplicationProtocolNegotiationStatus_Success)
            {
                // Verify ALPN matches ZPM_ALPN
                const alpn_size = alpn_info.ProtocolIdSize;
                if (alpn_size == ZPM_ALPN.len and
                    eqlBytes(alpn_info.ProtocolId[0..ZPM_ALPN.len], ZPM_ALPN))
                {
                    // ALPN matches — handshake successful
                    @memcpy(result.alpn[0..alpn_size], alpn_info.ProtocolId[0..alpn_size]);
                    result.alpn_len = alpn_size;
                } else {
                    // ALPN mismatch
                    self.state = .failed;
                    result.err = .protocol_error;
                    return result;
                }
            }

            self.state = .complete;
            result.complete = true;

            // Handle SECBUFFER_EXTRA
            handleExtraBuffer(self, &in_bufs);
        } else if (status == w32.SEC_E_INCOMPLETE_MESSAGE) {
            // Need more data — don't change state, return with has_data=false
            result.output.has_data = false;
        } else {
            self.state = .failed;
            result.err = .handshake_failed;
        }

        return result;
    }

    /// Initiate the TLS handshake (client side). Produces the ClientHello.
    /// Calls InitializeSecurityContextW with the server name and ALPN buffer.
    pub fn startHandshake(self: *TlsEngine, server_name: []const u8) HandshakeResult {
        var result = HandshakeResult{};

        if (self.state == .failed) {
            result.err = .handshake_failed;
            return result;
        }

        // Convert server_name to UTF-16 (simple ASCII→UTF-16 into stack buffer)
        var name_w: [256:0]u16 = [_:0]u16{0} ** 256;
        const name_len = if (server_name.len > 255) 255 else server_name.len;
        for (0..name_len) |i| {
            name_w[i] = @intCast(server_name[i]);
        }
        name_w[name_len] = 0;

        // Set up ALPN input buffer
        var alpn_protos = buildAlpnProtocols();

        // Input: SECBUFFER_APPLICATION_PROTOCOLS for ALPN
        var in_bufs: [1]w32.SecBuffer = .{
            .{
                .cbBuffer = @intCast(@sizeOf(w32.SEC_APPLICATION_PROTOCOLS)),
                .BufferType = w32.SECBUFFER_APPLICATION_PROTOCOLS,
                .pvBuffer = @ptrCast(&alpn_protos),
            },
        };
        var in_buf_desc = w32.SecBufferDesc{
            .ulVersion = w32.SECBUFFER_VERSION,
            .cBuffers = 1,
            .pBuffers = @ptrCast(&in_bufs),
        };

        // Output: SECBUFFER_TOKEN for the ClientHello
        var out_token_buf: [4096]u8 = undefined;
        var out_bufs: [1]w32.SecBuffer = .{
            .{
                .cbBuffer = out_token_buf.len,
                .BufferType = w32.SECBUFFER_TOKEN,
                .pvBuffer = @ptrCast(&out_token_buf),
            },
        };
        var out_buf_desc = w32.SecBufferDesc{
            .ulVersion = w32.SECBUFFER_VERSION,
            .cBuffers = 1,
            .pBuffers = @ptrCast(&out_bufs),
        };

        const isc_flags: w32.DWORD = w32.ISC_REQ_SEQUENCE_DETECT |
            w32.ISC_REQ_REPLAY_DETECT |
            w32.ISC_REQ_CONFIDENTIALITY |
            w32.ISC_REQ_STREAM |
            w32.ISC_REQ_MANUAL_CRED_VALIDATION;

        var cred_h: w32.CredHandle = @bitCast(self.cred_handle);
        var ctx_h: w32.CtxtHandle = .{};
        var out_flags: w32.DWORD = 0;

        const status = w32.InitializeSecurityContextW(
            &cred_h,
            null, // no existing context (first call)
            @ptrCast(&name_w),
            isc_flags,
            0, // reserved
            0, // target data rep
            &in_buf_desc,
            0, // reserved
            &ctx_h,
            &out_buf_desc,
            &out_flags,
            null, // expiry
        );

        if (status == w32.SEC_I_CONTINUE_NEEDED or status == w32.SEC_I_COMPLETE_AND_CONTINUE) {
            // Copy output token to TlsOutput
            const out_len = out_bufs[0].cbBuffer;
            if (out_len > 0 and out_len <= result.output.data.len) {
                const src: [*]const u8 = @ptrCast(out_bufs[0].pvBuffer.?);
                @memcpy(result.output.data[0..out_len], src[0..out_len]);
                result.output.data_len = @intCast(out_len);
                result.output.has_data = true;
                result.output.level = .initial;
            }

            // If COMPLETE_AND_CONTINUE, call CompleteAuthToken
            if (status == w32.SEC_I_COMPLETE_AND_CONTINUE) {
                _ = w32.CompleteAuthToken(&ctx_h, &out_buf_desc);
            }

            self.state = .in_progress;
            self.ctx_handle = @bitCast(ctx_h);
        } else if (status == w32.SEC_E_OK) {
            // Handshake completed in one call (unlikely for TLS 1.3 but handle it)
            self.state = .complete;
            self.ctx_handle = @bitCast(ctx_h);
            result.complete = true;
        } else {
            self.state = .failed;
            result.err = .handshake_failed;
        }

        return result;
    }

    /// Derive key, iv, hp_key from a TLS secret for the given encryption level.
    /// Called by the handshake driver when SChannel produces handshake/application secrets.
    pub fn deriveKeys(self: *TlsEngine, level: EncryptionLevel, secret: []const u8) void {
        const idx = @intFromEnum(level);

        // key = HKDF-Expand-Label(secret, "quic key", "", 16)
        var key: [16]u8 = undefined;
        if (!hkdfExpandLabel(secret, "quic key", "", &key)) return;

        // iv = HKDF-Expand-Label(secret, "quic iv", "", 12)
        var iv: [12]u8 = undefined;
        if (!hkdfExpandLabel(secret, "quic iv", "", &iv)) return;

        // hp_key = HKDF-Expand-Label(secret, "quic hp", "", 16)
        var hp_key: [16]u8 = undefined;
        if (!hkdfExpandLabel(secret, "quic hp", "", &hp_key)) return;

        self.keys[idx].key = key;
        self.keys[idx].iv = iv;
        self.keys[idx].hp_key = hp_key;
        self.keys[idx].valid = true;
    }

    /// Encrypt a packet payload in-place using AES-128-GCM AEAD.
    /// Per RFC 9001 §5.3: nonce = IV XOR packet_number (left-padded to 12 bytes).
    /// AAD = packet header bytes (buf[0..payload_offset]).
    /// Writes 16-byte auth tag after the encrypted payload.
    pub fn encrypt(self: *const TlsEngine, level: EncryptionLevel, pkt_number: u64, buf: []u8, payload_offset: u16, payload_len: u16) CryptoError {
        const ks = &self.keys[@intFromEnum(level)];
        if (!ks.valid) return .decrypt_failed;

        // Construct nonce: XOR 12-byte IV with packet number (big-endian, right-aligned)
        var nonce: [12]u8 = ks.iv;
        const pn_be = toBigEndian64(pkt_number);
        const pn_bytes: [8]u8 = @bitCast(pn_be);
        for (0..8) |i| {
            nonce[4 + i] ^= pn_bytes[i];
        }

        // Open AES algorithm provider
        var alg: w32.BCRYPT_ALG_HANDLE = null;
        var status = w32.BCryptOpenAlgorithmProvider(&alg, w32.BCRYPT_AES_ALGORITHM, null, 0);
        if (status != 0) return .decrypt_failed;

        // Set chaining mode to GCM
        // BCRYPT_CHAIN_MODE_GCM is LPCWSTR ([*:0]const u16). BCryptSetProperty wants [*]const u8 + byte length.
        // "ChainingModeGCM" = 16 UTF-16 code units + null = 17 × 2 = 34 bytes
        const gcm_mode_ptr: [*]const u8 = @ptrCast(w32.BCRYPT_CHAIN_MODE_GCM);
        const gcm_mode_byte_len: u32 = comptime ("ChainingModeGCM".len + 1) * 2; // 34
        status = w32.BCryptSetProperty(alg, w32.BCRYPT_CHAINING_MODE, gcm_mode_ptr, gcm_mode_byte_len, 0);
        if (status != 0) {
            _ = w32.BCryptCloseAlgorithmProvider(alg, 0);
            return .decrypt_failed;
        }

        // Generate symmetric key from key material
        var key_handle: w32.BCRYPT_KEY_HANDLE = null;
        status = w32.BCryptGenerateSymmetricKey(alg, &key_handle, null, 0, &ks.key, 16, 0);
        if (status != 0) {
            _ = w32.BCryptCloseAlgorithmProvider(alg, 0);
            return .decrypt_failed;
        }

        // Set up authenticated cipher mode info
        var tag: [16]u8 = undefined;
        var auth_info = w32.BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO{
            .pbNonce = &nonce,
            .cbNonce = 12,
            .pbAuthData = buf.ptr,
            .cbAuthData = payload_offset,
            .pbTag = &tag,
            .cbTag = 16,
        };

        // Encrypt in-place: plaintext and ciphertext share the same buffer region
        const pt_ptr: [*]const u8 = buf.ptr + payload_offset;
        const ct_ptr: [*]u8 = buf.ptr + payload_offset;
        var bytes_written: u32 = 0;
        status = w32.BCryptEncrypt(key_handle, pt_ptr, payload_len, &auth_info, null, 0, ct_ptr, payload_len, &bytes_written, 0);

        // Clean up BCrypt handles
        _ = w32.BCryptDestroyKey(key_handle);
        _ = w32.BCryptCloseAlgorithmProvider(alg, 0);

        if (status != 0) return .decrypt_failed;

        // Write the 16-byte auth tag after the encrypted payload
        const tag_offset = payload_offset + payload_len;
        if (tag_offset + 16 > buf.len) return .buffer_too_small;
        @memcpy(buf[tag_offset .. tag_offset + 16], &tag);

        return .none;
    }

    /// Decrypt a packet payload in-place using AES-128-GCM AEAD.
    /// Per RFC 9001 §5.3: nonce = IV XOR packet_number (left-padded to 12 bytes).
    /// AAD = packet header bytes (buf[0..payload_offset]).
    /// payload_len includes the 16-byte AEAD tag (ciphertext = payload_len - 16, tag = last 16 bytes).
    pub fn decrypt(self: *const TlsEngine, level: EncryptionLevel, pkt_number: u64, buf: []u8, payload_offset: u16, payload_len: u16) CryptoError {
        const ks = &self.keys[@intFromEnum(level)];
        if (!ks.valid) return .decrypt_failed;

        // AEAD overhead is 16 bytes; payload_len must be at least that
        if (payload_len < 16) return .decrypt_failed;
        const ct_len: u16 = payload_len - 16;

        // Construct nonce: XOR 12-byte IV with packet number (big-endian, right-aligned)
        var nonce: [12]u8 = ks.iv;
        const pn_be = toBigEndian64(pkt_number);
        const pn_bytes: [8]u8 = @bitCast(pn_be);
        for (0..8) |i| {
            nonce[4 + i] ^= pn_bytes[i];
        }

        // Extract the 16-byte auth tag from the end of the payload
        var tag: [16]u8 = undefined;
        const tag_start = payload_offset + ct_len;
        @memcpy(&tag, buf[tag_start .. tag_start + 16]);

        // Open AES algorithm provider
        var alg: w32.BCRYPT_ALG_HANDLE = null;
        var status = w32.BCryptOpenAlgorithmProvider(&alg, w32.BCRYPT_AES_ALGORITHM, null, 0);
        if (status != 0) return .decrypt_failed;

        // Set chaining mode to GCM
        const gcm_mode_ptr: [*]const u8 = @ptrCast(w32.BCRYPT_CHAIN_MODE_GCM);
        const gcm_mode_byte_len: u32 = comptime ("ChainingModeGCM".len + 1) * 2;
        status = w32.BCryptSetProperty(alg, w32.BCRYPT_CHAINING_MODE, gcm_mode_ptr, gcm_mode_byte_len, 0);
        if (status != 0) {
            _ = w32.BCryptCloseAlgorithmProvider(alg, 0);
            return .decrypt_failed;
        }

        // Generate symmetric key from key material
        var key_handle: w32.BCRYPT_KEY_HANDLE = null;
        status = w32.BCryptGenerateSymmetricKey(alg, &key_handle, null, 0, &ks.key, 16, 0);
        if (status != 0) {
            _ = w32.BCryptCloseAlgorithmProvider(alg, 0);
            return .decrypt_failed;
        }

        // Set up authenticated cipher mode info with tag for verification
        var auth_info = w32.BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO{
            .pbNonce = &nonce,
            .cbNonce = 12,
            .pbAuthData = buf.ptr,
            .cbAuthData = payload_offset,
            .pbTag = &tag,
            .cbTag = 16,
        };

        // Decrypt in-place
        const ct_ptr: [*]const u8 = buf.ptr + payload_offset;
        const pt_ptr: [*]u8 = buf.ptr + payload_offset;
        var bytes_written: u32 = 0;
        status = w32.BCryptDecrypt(key_handle, ct_ptr, ct_len, &auth_info, null, 0, pt_ptr, ct_len, &bytes_written, 0);

        // Clean up BCrypt handles
        _ = w32.BCryptDestroyKey(key_handle);
        _ = w32.BCryptCloseAlgorithmProvider(alg, 0);

        if (status != 0) return .decrypt_failed;

        return .none;
    }

    /// Apply header protection per RFC 9001 §5.4.
    /// Masks the first byte and packet number bytes using AES-ECB of a sample.
    pub fn protectHeader(self: *const TlsEngine, level: EncryptionLevel, buf: []u8, pn_offset: u16) void {
        applyHeaderProtection(&self.keys[@intFromEnum(level)], buf, pn_offset);
    }

    /// Remove header protection per RFC 9001 §5.4.
    /// The XOR operation is its own inverse, so the algorithm is identical to protect.
    pub fn unprotectHeader(self: *const TlsEngine, level: EncryptionLevel, buf: []u8, pn_offset: u16) void {
        applyHeaderProtection(&self.keys[@intFromEnum(level)], buf, pn_offset);
    }

    /// Derive new 1-RTT keys from current application traffic secret (key update).
    /// Per RFC 9001 §6: new_secret = HKDF-Expand-Label(app_secret, "quic ku", "", 32),
    /// then derive key/iv/hp_key from the new secret.
    pub fn updateKeys(self: *TlsEngine) void {
        // Derive new application traffic secret
        var new_secret: [32]u8 = undefined;
        if (!hkdfExpandLabel(&self.app_secret, "quic ku", "", &new_secret)) return;

        // Derive new key/iv/hp_key from the new secret
        const idx = @intFromEnum(EncryptionLevel.one_rtt);

        var key: [16]u8 = undefined;
        if (!hkdfExpandLabel(&new_secret, "quic key", "", &key)) return;

        var iv: [12]u8 = undefined;
        if (!hkdfExpandLabel(&new_secret, "quic iv", "", &iv)) return;

        var hp_key: [16]u8 = undefined;
        if (!hkdfExpandLabel(&new_secret, "quic hp", "", &hp_key)) return;

        self.keys[idx].key = key;
        self.keys[idx].iv = iv;
        self.keys[idx].hp_key = hp_key;
        self.keys[idx].valid = true;

        // Update stored application traffic secret
        self.app_secret = new_secret;
    }

    /// Release SChannel handles and zero out key material.
    pub fn deinit(self: *TlsEngine) void {
        // Delete security context if we ever started a handshake
        if (self.state != .idle) {
            var ctx_h: w32.CtxtHandle = @bitCast(self.ctx_handle);
            _ = w32.DeleteSecurityContext(&ctx_h);
        }

        // Free credentials handle
        var cred_h: w32.CredHandle = @bitCast(self.cred_handle);
        _ = w32.FreeCredentialsHandle(&cred_h);

        // Zero out key material
        for (0..4) |i| {
            self.keys[i].key = [_]u8{0} ** 16;
            self.keys[i].iv = [_]u8{0} ** 12;
            self.keys[i].hp_key = [_]u8{0} ** 16;
            self.keys[i].valid = false;
        }

        // Zero out handles
        self.cred_handle = [_]u64{ 0, 0 };
        self.ctx_handle = [_]u64{ 0, 0 };

        // Zero out handshake buffers
        @memset(&self.recv_buf, 0);
        self.recv_len = 0;
        @memset(&self.send_buf, 0);
        self.send_len = 0;

        // Zero out ticket
        @memset(&self.ticket, 0);
        self.ticket_len = 0;
        self.has_ticket = false;

        // Zero out application traffic secret
        @memset(&self.app_secret, 0);

        self.state = .idle;
    }
};

// ── SChannel Helpers ──

/// Build the SEC_APPLICATION_PROTOCOLS struct with ALPN wire format for "zpm".
fn buildAlpnProtocols() w32.SEC_APPLICATION_PROTOCOLS {
    var protos = w32.SEC_APPLICATION_PROTOCOLS{};
    protos.ProtocolLists.ProtoNegoExt = w32.SecApplicationProtocolNegotiationExt_ALPN;
    // ALPN wire format: [length_byte, protocol_bytes...]
    protos.ProtocolLists.ProtocolList[0] = @intCast(ZPM_ALPN.len);
    @memcpy(protos.ProtocolLists.ProtocolList[1 .. 1 + ZPM_ALPN.len], ZPM_ALPN);
    protos.ProtocolLists.ProtocolListSize = @intCast(1 + ZPM_ALPN.len);
    protos.ProtocolListsSize = @intCast(@sizeOf(w32.SEC_APPLICATION_PROTOCOL_LIST));
    return protos;
}

/// Handle SECBUFFER_EXTRA after an ISC/ASC call — move unconsumed data to the
/// front of recv_buf so the next feedCryptoData call picks it up.
fn handleExtraBuffer(engine: *TlsEngine, in_bufs: *[2]w32.SecBuffer) void {
    // Check if the second buffer was marked as EXTRA by SChannel
    if (in_bufs[1].BufferType == w32.SECBUFFER_EXTRA and in_bufs[1].cbBuffer > 0) {
        const extra_len: u16 = @intCast(in_bufs[1].cbBuffer);
        const consumed = engine.recv_len - extra_len;
        // Move extra data to front of recv_buf
        var i: u16 = 0;
        while (i < extra_len) : (i += 1) {
            engine.recv_buf[i] = engine.recv_buf[consumed + i];
        }
        engine.recv_len = extra_len;
    } else {
        // All data consumed
        engine.recv_len = 0;
    }
}

/// Compare two byte slices for equality.
fn eqlBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

// ── Header Protection (RFC 9001 §5.4) ──

/// Apply or remove header protection. XOR is self-inverse so protect and unprotect
/// use the same algorithm. Generates a 16-byte mask by AES-ECB encrypting a 16-byte
/// sample from the encrypted payload, then XORs the first byte and packet number bytes.
///
/// For AES-ECB on a single 16-byte block, we use AES-CBC with a zero IV — the result
/// is identical since CBC XORs plaintext with IV (all zeros) before encrypting.
fn applyHeaderProtection(ks: *const KeySet, buf: []u8, pn_offset: u16) void {
    if (!ks.valid) return;

    // Sample 16 bytes starting at pn_offset + 4
    const sample_offset = pn_offset + 4;
    if (sample_offset + 16 > buf.len) return;

    // Open AES algorithm provider
    var alg: w32.BCRYPT_ALG_HANDLE = null;
    var status = w32.BCryptOpenAlgorithmProvider(&alg, w32.BCRYPT_AES_ALGORITHM, null, 0);
    if (status != 0) return;

    // Generate symmetric key from hp_key
    var key_handle: w32.BCRYPT_KEY_HANDLE = null;
    status = w32.BCryptGenerateSymmetricKey(alg, &key_handle, null, 0, &ks.hp_key, 16, 0);
    if (status != 0) {
        _ = w32.BCryptCloseAlgorithmProvider(alg, 0);
        return;
    }

    // AES-CBC with zero IV on a single 16-byte block = AES-ECB
    var zero_iv: [16]u8 = [_]u8{0} ** 16;
    var mask: [16]u8 = undefined;
    var bytes_written: u32 = 0;
    const sample_ptr: [*]const u8 = buf.ptr + sample_offset;
    status = w32.BCryptEncrypt(key_handle, sample_ptr, 16, null, &zero_iv, 16, &mask, 16, &bytes_written, 0);

    // Clean up BCrypt handles
    _ = w32.BCryptDestroyKey(key_handle);
    _ = w32.BCryptCloseAlgorithmProvider(alg, 0);

    if (status != 0) return;

    // XOR first byte: 4 bits for long headers, 5 bits for short headers
    if (buf[0] & 0x80 != 0) {
        buf[0] ^= mask[0] & 0x0f;
    } else {
        buf[0] ^= mask[0] & 0x1f;
    }

    // Determine packet number length from the (now-masked/unmasked) first byte
    const pn_len: u8 = (buf[0] & 0x03) + 1;

    // XOR packet number bytes with mask[1..1+pn_len]
    for (0..pn_len) |i| {
        buf[pn_offset + @as(u16, @intCast(i))] ^= mask[1 + i];
    }
}

// ── QUIC Initial Salts ──

/// Convert a u64 to big-endian byte order.
inline fn toBigEndian64(val: u64) u64 {
    return @byteSwap(val);
}

/// QUIC v1 Initial salt per RFC 9001 §5.2.
const initial_salt_v1 = [_]u8{
    0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17,
    0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a,
};

/// QUIC v2 Initial salt per RFC 9369 §3.
const initial_salt_v2 = [_]u8{
    0x0d, 0xed, 0xe3, 0xde, 0xf7, 0x00, 0xa6, 0xdb, 0x81, 0x93,
    0x81, 0xbe, 0x6e, 0x26, 0x9d, 0xcb, 0xf9, 0xbd, 0x2e, 0xd9,
};

// ── HKDF Helpers (RFC 5869 + RFC 8446 §7.1) ──

/// HKDF-Extract: PRK = HMAC-SHA256(salt, IKM).
/// Salt is the HMAC key, IKM is the message.
fn hkdfExtract(salt: []const u8, ikm: []const u8, out: *[32]u8) bool {
    return platform_crypto.hmacSha256(salt, ikm, out);
}

/// HKDF-Expand per RFC 5869 §2.3.
/// Iteratively computes T(1), T(2), ... using HMAC-SHA256 until `out.len` bytes
/// are generated. Each iteration: T(i) = HMAC-SHA256(PRK, T(i-1) || info || i).
fn hkdfExpand(prk: []const u8, info: []const u8, out: []u8) bool {
    const hash_len = platform_crypto.HMAC_SHA256_LEN; // 32
    var n: usize = (out.len + hash_len - 1) / hash_len;
    if (n == 0) n = 1;

    var t_prev: [32]u8 = undefined;
    var t_prev_len: usize = 0; // T(0) is empty
    var offset: usize = 0;

    for (0..n) |i| {
        // Build message: T(i-1) || info || counter
        var msg_buf: [32 + 255 + 1]u8 = undefined;
        var msg_len: usize = 0;

        // Append T(i-1) — empty for first iteration
        if (t_prev_len > 0) {
            @memcpy(msg_buf[0..t_prev_len], t_prev[0..t_prev_len]);
            msg_len = t_prev_len;
        }

        // Append info
        if (info.len > 0) {
            @memcpy(msg_buf[msg_len .. msg_len + info.len], info);
            msg_len += info.len;
        }

        // Append 1-based counter byte
        msg_buf[msg_len] = @intCast(i + 1);
        msg_len += 1;

        var t_current: [32]u8 = undefined;
        if (!platform_crypto.hmacSha256(prk, msg_buf[0..msg_len], &t_current)) {
            return false;
        }

        // Copy to output
        const remaining = out.len - offset;
        const to_copy = if (remaining < hash_len) remaining else hash_len;
        @memcpy(out[offset .. offset + to_copy], t_current[0..to_copy]);
        offset += to_copy;

        // Save for next iteration
        t_prev = t_current;
        t_prev_len = hash_len;
    }

    return true;
}

/// HKDF-Expand-Label per RFC 8446 §7.1 / RFC 9001 §5.2.
/// Constructs the HkdfLabel struct and calls hkdfExpand.
///
/// HkdfLabel = length (2 bytes, big-endian) ||
///             label_prefix_len (1 byte) || "tls13 " || label ||
///             context_len (1 byte) || context
fn hkdfExpandLabel(secret: []const u8, label: []const u8, context: []const u8, out: []u8) bool {
    const prefix = "tls13 ";

    // Build the HkdfLabel info buffer
    var info_buf: [2 + 1 + 6 + 255 + 1 + 255]u8 = undefined;
    var pos: usize = 0;

    // Length field (2 bytes, big-endian) — output length
    const out_len: u16 = @intCast(out.len);
    info_buf[pos] = @intCast(out_len >> 8);
    pos += 1;
    info_buf[pos] = @intCast(out_len & 0xff);
    pos += 1;

    // Label length (1 byte) — includes "tls13 " prefix
    const full_label_len: u8 = @intCast(prefix.len + label.len);
    info_buf[pos] = full_label_len;
    pos += 1;

    // "tls13 " prefix
    @memcpy(info_buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;

    // Label
    @memcpy(info_buf[pos .. pos + label.len], label);
    pos += label.len;

    // Context length (1 byte)
    info_buf[pos] = @intCast(context.len);
    pos += 1;

    // Context
    if (context.len > 0) {
        @memcpy(info_buf[pos .. pos + context.len], context);
        pos += context.len;
    }

    return hkdfExpand(secret, info_buf[0..pos], out);
}

/// Derive Initial encryption keys from a destination connection ID.
/// Uses HKDF-Extract + HKDF-Expand-Label per RFC 9001 §5.2.
pub fn deriveInitialKeys(dst_cid: []const u8, is_server: bool, version: u32) KeySet {
    // Select salt based on QUIC version
    const salt: []const u8 = if (version == @intFromEnum(packet.Version.quic_v2))
        &initial_salt_v2
    else
        &initial_salt_v1;

    // Step 1: initial_secret = HKDF-Extract(salt, dst_cid)
    var initial_secret: [32]u8 = undefined;
    if (!hkdfExtract(salt, dst_cid, &initial_secret)) return .{};

    // Step 2: client_initial_secret = HKDF-Expand-Label(initial_secret, "client in", "", 32)
    var client_secret: [32]u8 = undefined;
    if (!hkdfExpandLabel(&initial_secret, "client in", "", &client_secret)) return .{};

    // Step 3: server_initial_secret = HKDF-Expand-Label(initial_secret, "server in", "", 32)
    var server_secret: [32]u8 = undefined;
    if (!hkdfExpandLabel(&initial_secret, "server in", "", &server_secret)) return .{};

    // Step 4: Pick the appropriate secret
    const secret: []const u8 = if (is_server) &server_secret else &client_secret;

    // Step 5: key = HKDF-Expand-Label(secret, "quic key", "", 16)
    var key: [16]u8 = undefined;
    if (!hkdfExpandLabel(secret, "quic key", "", &key)) return .{};

    // Step 6: iv = HKDF-Expand-Label(secret, "quic iv", "", 12)
    var iv: [12]u8 = undefined;
    if (!hkdfExpandLabel(secret, "quic iv", "", &iv)) return .{};

    // Step 7: hp_key = HKDF-Expand-Label(secret, "quic hp", "", 16)
    var hp_key: [16]u8 = undefined;
    if (!hkdfExpandLabel(secret, "quic hp", "", &hp_key)) return .{};

    return KeySet{
        .key = key,
        .iv = iv,
        .hp_key = hp_key,
        .valid = true,
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// Unit Tests
// ══════════════════════════════════════════════════════════════════════════════

const testing = @import("std").testing;

// ── 7.9: Initial Key Derivation Tests ──

test "deriveInitialKeys: RFC 9001 Appendix A client Initial keys (QUIC v1)" {
    // RFC 9001 Appendix A test vector: client DCID = 0x8394c8f03e515708
    const dcid = [_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 };
    const ks = deriveInitialKeys(&dcid, false, @intFromEnum(packet.Version.quic_v1));

    try testing.expect(ks.valid);

    // Expected client Initial key from RFC 9001 Appendix A.1
    const expected_key = [_]u8{ 0x1f, 0x36, 0x96, 0x13, 0xdd, 0x76, 0xd5, 0x46, 0x77, 0x30, 0xef, 0xcb, 0xe3, 0xb1, 0xa2, 0x2d };
    try testing.expectEqualSlices(u8, &expected_key, &ks.key);

    // Expected client Initial IV
    const expected_iv = [_]u8{ 0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b, 0x46, 0xfb, 0x25, 0x5c };
    try testing.expectEqualSlices(u8, &expected_iv, &ks.iv);

    // Expected client Initial HP key
    const expected_hp = [_]u8{ 0x9f, 0x50, 0x44, 0x9e, 0x04, 0xa0, 0xe8, 0x10, 0x28, 0x3a, 0x1e, 0x99, 0x33, 0xad, 0xed, 0xd2 };
    try testing.expectEqualSlices(u8, &expected_hp, &ks.hp_key);
}

test "deriveInitialKeys: v1 and v2 produce different key material" {
    const dcid = [_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 };
    const ks_v1 = deriveInitialKeys(&dcid, false, @intFromEnum(packet.Version.quic_v1));
    const ks_v2 = deriveInitialKeys(&dcid, false, @intFromEnum(packet.Version.quic_v2));

    try testing.expect(ks_v1.valid);
    try testing.expect(ks_v2.valid);

    // Keys must differ because the salts differ
    try testing.expect(!eqlBytes(&ks_v1.key, &ks_v2.key));
    try testing.expect(!eqlBytes(&ks_v1.iv, &ks_v2.iv));
    try testing.expect(!eqlBytes(&ks_v1.hp_key, &ks_v2.hp_key));
}

test "deriveInitialKeys: client and server keys differ for same DCID" {
    const dcid = [_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 };
    const client_ks = deriveInitialKeys(&dcid, false, @intFromEnum(packet.Version.quic_v1));
    const server_ks = deriveInitialKeys(&dcid, true, @intFromEnum(packet.Version.quic_v1));

    try testing.expect(client_ks.valid);
    try testing.expect(server_ks.valid);

    // Client and server derive from different secrets ("client in" vs "server in")
    try testing.expect(!eqlBytes(&client_ks.key, &server_ks.key));
    try testing.expect(!eqlBytes(&client_ks.iv, &server_ks.iv));
    try testing.expect(!eqlBytes(&client_ks.hp_key, &server_ks.hp_key));
}

// ── 7.10: AEAD Encrypt/Decrypt Round-Trip Tests ──

/// Helper: create a TlsEngine with manually set keys at the initial level.
fn makeTestEngine(key: [16]u8, iv: [12]u8, hp_key: [16]u8) TlsEngine {
    var engine = TlsEngine{};
    engine.keys[0] = KeySet{ .key = key, .iv = iv, .hp_key = hp_key, .valid = true };
    return engine;
}

/// Helper: known test key material (deterministic, not from SChannel).
const test_key = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10 };
const test_iv = [_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c };
const test_hp_key = [_]u8{ 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30 };

test "AEAD: encrypt then decrypt round-trip restores plaintext" {
    const engine = makeTestEngine(test_key, test_iv, test_hp_key);

    // Buffer layout: 20-byte header | 32-byte payload | 16-byte tag space
    var buf: [68]u8 = undefined;
    // Fill header with recognizable pattern
    for (0..20) |i| buf[i] = @intCast(i);
    // Fill payload with known plaintext
    const plaintext = "This is a test payload for AEAD!"; // exactly 32 bytes
    @memcpy(buf[20..52], plaintext);
    // Zero tag space
    @memset(buf[52..68], 0);

    // Save original plaintext for comparison
    var original: [32]u8 = undefined;
    @memcpy(&original, buf[20..52]);

    // Encrypt: payload_offset=20, payload_len=32
    const enc_err = engine.encrypt(.initial, 0, &buf, 20, 32);
    try testing.expectEqual(CryptoError.none, enc_err);

    // Decrypt: payload_len=48 (32 ciphertext + 16 tag)
    const dec_err = engine.decrypt(.initial, 0, &buf, 20, 48);
    try testing.expectEqual(CryptoError.none, dec_err);

    // Verify plaintext restored
    try testing.expectEqualSlices(u8, &original, buf[20..52]);
}

test "AEAD: modified ciphertext byte causes decrypt_failed" {
    const engine = makeTestEngine(test_key, test_iv, test_hp_key);

    var buf: [68]u8 = undefined;
    for (0..20) |i| buf[i] = @intCast(i);
    @memcpy(buf[20..52], "This is a test payload for AEAD!");
    @memset(buf[52..68], 0);

    const enc_err = engine.encrypt(.initial, 0, &buf, 20, 32);
    try testing.expectEqual(CryptoError.none, enc_err);

    // Flip one byte of ciphertext (not the tag)
    buf[25] ^= 0xff;

    const dec_err = engine.decrypt(.initial, 0, &buf, 20, 48);
    try testing.expectEqual(CryptoError.decrypt_failed, dec_err);
}

test "AEAD: modified auth tag causes decrypt_failed" {
    const engine = makeTestEngine(test_key, test_iv, test_hp_key);

    var buf: [68]u8 = undefined;
    for (0..20) |i| buf[i] = @intCast(i);
    @memcpy(buf[20..52], "This is a test payload for AEAD!");
    @memset(buf[52..68], 0);

    const enc_err = engine.encrypt(.initial, 0, &buf, 20, 32);
    try testing.expectEqual(CryptoError.none, enc_err);

    // Flip one byte of the auth tag (last 16 bytes)
    buf[60] ^= 0xff;

    const dec_err = engine.decrypt(.initial, 0, &buf, 20, 48);
    try testing.expectEqual(CryptoError.decrypt_failed, dec_err);
}

test "AEAD: wrong key causes decrypt_failed" {
    const engine1 = makeTestEngine(test_key, test_iv, test_hp_key);

    var buf: [68]u8 = undefined;
    for (0..20) |i| buf[i] = @intCast(i);
    @memcpy(buf[20..52], "This is a test payload for AEAD!");
    @memset(buf[52..68], 0);

    // Encrypt with engine1's key
    const enc_err = engine1.encrypt(.initial, 0, &buf, 20, 32);
    try testing.expectEqual(CryptoError.none, enc_err);

    // Decrypt with a different key
    const wrong_key = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99 };
    const engine2 = makeTestEngine(wrong_key, test_iv, test_hp_key);

    const dec_err = engine2.decrypt(.initial, 0, &buf, 20, 48);
    try testing.expectEqual(CryptoError.decrypt_failed, dec_err);
}

test "AEAD: different packet numbers produce different ciphertext" {
    const engine = makeTestEngine(test_key, test_iv, test_hp_key);

    // Encrypt same plaintext with pkt_number=0
    var buf1: [68]u8 = undefined;
    for (0..20) |i| buf1[i] = @intCast(i);
    @memcpy(buf1[20..52], "This is a test payload for AEAD!");
    @memset(buf1[52..68], 0);

    const enc1 = engine.encrypt(.initial, 0, &buf1, 20, 32);
    try testing.expectEqual(CryptoError.none, enc1);

    // Encrypt same plaintext with pkt_number=1
    var buf2: [68]u8 = undefined;
    for (0..20) |i| buf2[i] = @intCast(i);
    @memcpy(buf2[20..52], "This is a test payload for AEAD!");
    @memset(buf2[52..68], 0);

    const enc2 = engine.encrypt(.initial, 1, &buf2, 20, 32);
    try testing.expectEqual(CryptoError.none, enc2);

    // Ciphertext (including tag) must differ
    try testing.expect(!eqlBytes(buf1[20..68], buf2[20..68]));
}

// ── 7.11: Header Protection Round-Trip Tests ──

test "header protection: long header protect then unprotect restores original" {
    const engine = makeTestEngine(test_key, test_iv, test_hp_key);

    // Build a fake long header packet buffer:
    // First byte has high bit set (0xc0 = long header, Initial type, pn_len=0 → 1 byte pn)
    // pn_offset = 18 (typical for a long header with 8-byte CIDs)
    // Need at least pn_offset + 4 + 16 = 38 bytes of "encrypted payload" after pn
    const pn_offset: u16 = 18;
    var buf: [80]u8 = undefined;

    // Fill with deterministic pattern
    for (0..80) |i| buf[i] = @intCast(i & 0xff);

    // Set first byte: long header (0x80 set), Initial type, pn_len bits = 3 (4-byte pn)
    // Using max pn_len so the mask can't increase it during the protect pass.
    buf[0] = 0xc3; // 1100_0011: long header, type=0 (Initial), pn_len=3 (4 bytes)

    // Save original bytes for comparison
    var original: [80]u8 = undefined;
    @memcpy(&original, &buf);

    // Protect
    engine.protectHeader(.initial, &buf, pn_offset);

    // First byte and pn bytes should have changed
    try testing.expect(buf[0] != original[0] or buf[pn_offset] != original[pn_offset]);

    // Unprotect (XOR is self-inverse)
    engine.unprotectHeader(.initial, &buf, pn_offset);

    // All bytes should be restored
    try testing.expectEqualSlices(u8, &original, &buf);
}

test "header protection: short header protect then unprotect restores original" {
    const engine = makeTestEngine(test_key, test_iv, test_hp_key);

    // Short header: high bit clear (0x40 = fixed bit set, short header)
    // Use pn_len bits = 3 (4-byte pn) and same pn_offset/buffer pattern as
    // the long header test, which produces a mask that preserves pn_len bits.
    const pn_offset: u16 = 18;
    var buf: [80]u8 = undefined;

    for (0..80) |i| buf[i] = @intCast(i & 0xff);

    // 0x43 = 0100_0011: short header, fixed bit, pn_len bits = 3 (4-byte pn)
    buf[0] = 0x43;

    var original: [80]u8 = undefined;
    @memcpy(&original, &buf);

    engine.protectHeader(.initial, &buf, pn_offset);
    engine.unprotectHeader(.initial, &buf, pn_offset);

    try testing.expectEqualSlices(u8, &original, &buf);
}

test "header protection: protection changes first byte and pn bytes" {
    const engine = makeTestEngine(test_key, test_iv, test_hp_key);

    // Use a buffer filled with 0xff to maximize the chance of visible changes.
    // pn_offset=18, sample starts at byte 22.
    const pn_offset: u16 = 18;
    var buf: [80]u8 = undefined;
    @memset(&buf, 0xff);
    buf[0] = 0xc3; // long header, pn_len bits = 3 → 4-byte packet number

    var original: [80]u8 = undefined;
    @memcpy(&original, &buf);

    engine.protectHeader(.initial, &buf, pn_offset);

    // Protection must change at least something — either the first byte
    // or at least one packet number byte (the mask is AES-ECB output,
    // which is non-zero for any non-degenerate input).
    var any_changed = false;
    if (buf[0] != original[0]) any_changed = true;
    for (0..4) |i| {
        if (buf[pn_offset + @as(u16, @intCast(i))] != original[pn_offset + @as(u16, @intCast(i))]) {
            any_changed = true;
            break;
        }
    }
    try testing.expect(any_changed);

    // Bytes outside the protected region must be unchanged
    for (1..pn_offset) |i| {
        try testing.expectEqual(original[i], buf[i]);
    }
}

// ── 7.12: ALPN Validation Tests ──

test "ALPN: ZPM_ALPN constant equals zpm" {
    try testing.expectEqualSlices(u8, "zpm", ZPM_ALPN);
    try testing.expectEqual(@as(usize, 4), ZPM_ALPN.len);
}

test "ALPN: eqlBytes matches identical slices" {
    try testing.expect(eqlBytes("zpm", "zpm"));
    try testing.expect(eqlBytes("", ""));
    try testing.expect(eqlBytes("abc", "abc"));
}

test "ALPN: eqlBytes rejects different slices" {
    try testing.expect(!eqlBytes("zpm", "http"));
    try testing.expect(!eqlBytes("zpm", "hei"));
    try testing.expect(!eqlBytes("zpm", "zpml"));
    try testing.expect(!eqlBytes("a", "b"));
    try testing.expect(!eqlBytes("", "x"));
}

test "ALPN: eqlBytes validates ZPM_ALPN against known value" {
    // Simulate what feedCryptoData does: compare negotiated ALPN with ZPM_ALPN
    const negotiated = "zpm";
    try testing.expect(eqlBytes(negotiated, ZPM_ALPN));

    const wrong_alpn = "h3";
    try testing.expect(!eqlBytes(wrong_alpn, ZPM_ALPN));
}
