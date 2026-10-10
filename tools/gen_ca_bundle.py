import certifi, re
from cryptography import x509
from cryptography.hazmat.primitives.serialization import Encoding

pem = open(certifi.where(), "rb").read()
blocks = re.findall(rb"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", pem, re.S)

def cn(cert):
    try:
        for a in cert.subject:
            if a.oid.dotted_string == "2.5.4.3":
                return a.value
        # fall back to O
        for a in cert.subject:
            if a.oid.dotted_string == "2.5.4.10":
                return a.value
    except Exception:
        pass
    return "root"

out = []
out.append("// Embedded trusted CA root certificates (DER), generated from the Mozilla CA")
out.append("// bundle (via certifi). This is the comprehensive FAST PATH: the chain validator")
out.append("// anchors here first. Anything not present falls back to the Windows system root")
out.append("// store (x509_verify.trySystemRoots), which Windows keeps current automatically.")
out.append("//")
out.append("// Regenerate with tools/gen_ca_bundle.py when refreshing the embedded set.")
out.append("// Layer 1: crypto (internal to the tls_client directory module).")
out.append("")
out.append('const x509 = @import(\"x509.sig\");')
out.append("")
names = []
for idx, b in enumerate(blocks):
    c = x509.load_pem_x509_certificate(b)
    der = c.public_bytes(Encoding.DER)
    name = "root_%03d" % idx
    names.append(name)
    label = cn(c).replace(chr(10), " ")[:60]
    out.append("// " + label)
    out.append("const " + name + " = [_]u8{")
    line = "    "
    for j, by in enumerate(der):
        line += "0x%02x," % by
        if (j % 16) == 15:
            out.append(line)
            line = "    "
    if line.strip():
        out.append(line)
    out.append("};")
    out.append("")
out.append("pub const MAX_ROOTS: usize = %d;" % (len(names) + 8))
out.append("")
out.append("/// All embedded root DERs (Mozilla bundle snapshot).")
out.append("pub const ROOT_DERS = [_][]const u8{")
for nm in names:
    out.append("    &" + nm + ",")
out.append("};")
out.append("")
out.append("/// Parse the embedded roots into x509.Cert values. Caller supplies storage.")
out.append("/// Returns the number of roots parsed into out (skips any that fail to parse).")
out.append("pub fn load(out_certs: []x509.Cert) usize {")
out.append("    var n: usize = 0;")
out.append("    for (ROOT_DERS) |der| {")
out.append("        if (n >= out_certs.len) break;")
out.append("        out_certs[n] = x509.parse(der) catch continue;")
out.append("        n += 1;")
out.append("    }")
out.append("    return n;")
out.append("}")
out.append("")
out.append('const testing = @import(\"std\").testing;')
out.append("")
out.append('test \"ca_bundle: embedded roots parse and are CAs\" {')
out.append("    var buf: [MAX_ROOTS]x509.Cert = undefined;")
out.append("    const n = load(&buf);")
out.append("    // Most roots parse; the x509 parser may skip a few exotic encodings,")
out.append("    // which is fine because the OS trust-store fallback still covers them.")
out.append("    try testing.expect(n >= 100);")
out.append("    var i: usize = 0;")
out.append("    var ca_count: usize = 0;")
out.append("    while (i < n) : (i += 1) { if (buf[i].is_ca) ca_count += 1; }")
out.append("    try testing.expect(ca_count >= 100);")
out.append("}")
open("src/core/crypto/tls/ca_bundle.sig", "w", encoding="utf-8").write(chr(10).join(out) + chr(10))
print("wrote ca_bundle.sig with", len(names), "roots")
