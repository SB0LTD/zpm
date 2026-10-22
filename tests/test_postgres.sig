//! Executable PostgreSQL protocol contracts, including malformed framing.
const std = @import("std");
const pg = @import("postgres");
const sql = @import("sql");
const Raw = sql.Database(.{.tables=2,.columns=4,.rows_per_table=4,.text_bytes=64});
const DB = struct {
    pub const Result = Raw.Result;
    raw: Raw = .{}, snapshot: Raw = .{}, status: u8 = 'I',
    pub fn execute(self: *@This(), source: []const u8, result: *Result) !void {
        if(self.status == 'E') return error.TransactionFailed;
        self.raw.execute(source,result) catch |err| { self.failTransaction(); return err; };
    }
    pub fn beginTransaction(self: *@This()) !void {
        if(self.status == 'I') { self.snapshot=self.raw; self.status='T'; }
    }
    pub fn commitTransaction(self: *@This()) !void {
        if(self.status == 'E') self.raw=self.snapshot;
        self.status='I';
    }
    pub fn rollbackTransaction(self: *@This()) !void {
        if(self.status != 'I') self.raw=self.snapshot;
        self.status='I';
    }
    pub fn failTransaction(self: *@This()) void { if(self.status == 'T') self.status='E'; }
    pub fn transactionStatus(self: *@This()) u8 { return self.status; }
};
const Session = pg.Session(DB);
var assertions: usize = 0;
var packets: usize = 0;
var fuzz_inputs: usize = 0;
fn check(value: bool) !void { assertions+=1; if(!value) return error.PostgresContractFailed; }
fn equal(a: []const u8, b: []const u8) bool { return std.mem.eql(u8,a,b); }
fn u32be(b: []const u8) u32 { return (@as(u32,b[0]) << 24) | (@as(u32,b[1]) << 16) | (@as(u32,b[2]) << 8) | b[3]; }
fn put32(b: []u8,n: u32) void { b[0]=@truncate(n >> 24); b[1]=@truncate(n >> 16); b[2]=@truncate(n >> 8); b[3]=@truncate(n); }
const Packet = struct {
    bytes: [pg.max_packet+1]u8 = @splat(0), len: usize = 5,
    fn init(tag: u8) Packet { var p: Packet=.{}; p.bytes[0]=tag; return p; }
    fn append(self: *Packet,b: []const u8) void { @memcpy(self.bytes[self.len..][0..b.len],b); self.len+=b.len; }
    fn byte(self: *Packet,b: u8) void { self.bytes[self.len]=b; self.len+=1; }
    fn string(self: *Packet,b: []const u8) void { self.append(b); self.byte(0); }
    fn number16(self: *Packet,n: u16) void { self.byte(@truncate(n >> 8)); self.byte(@truncate(n)); }
    fn number32(self: *Packet,n: u32) void { put32(self.bytes[self.len..][0..4],n); self.len+=4; }
    fn slice(self: *Packet) []const u8 { put32(self.bytes[1..5],@intCast(self.len-1)); return self.bytes[0..self.len]; }
};
const Frames = struct {
    const Frame = struct { tag: u8, body: []const u8 };
    bytes: []const u8, at: usize=0,
    fn next(self: *Frames) !?Frame {
        if(self.at == self.bytes.len) return null;
        try check(self.bytes.len-self.at >= 5);
        const n=u32be(self.bytes[self.at+1..][0..4]);
        try check(n >= 4 and n <= self.bytes.len-self.at-1);
        const result: Frame=.{.tag=self.bytes[self.at],.body=self.bytes[self.at+5..self.at+1+n]};
        self.at+=1+n; return result;
    }
};
fn tags(bytes: []const u8, wanted: []const u8) !void {
    var frames: Frames=.{.bytes=bytes};
    for(wanted) |tag| { const f=(try frames.next()) orelse return error.MissingFrame; try check(f.tag == tag); }
    try check((try frames.next()) == null);
}
fn state(bytes: []const u8, wanted: []const u8) !void {
    var f: Frames=.{.bytes=bytes};
    const first=(try f.next()) orelse return error.MissingError;
    try check(first.tag == 'E');
    var i: usize=0;
    while(i < first.body.len and first.body[i] != 0) {
        const kind=first.body[i]; i+=1; const begin=i;
        while(i < first.body.len and first.body[i] != 0) : (i+=1) {}
        try check(i < first.body.len);
        if(kind == 'C') { try check(equal(first.body[begin..i],wanted)); return; }
        i+=1;
    }
    return error.MissingSqlstate;
}
var output: [Session.responseCapacity()]u8 = undefined;
fn send(s: *Session, db: *DB, p: *Packet) ![]const u8 {
    const bytes=p.slice(); const reply=try s.handle(db,bytes,&output);
    try check(reply.consumed == bytes.len and !reply.close); packets+=1;
    return output[0..reply.written];
}
fn query(s: *Session,db: *DB,source: []const u8) ![]const u8 { var p=Packet.init('Q'); p.string(source); return send(s,db,&p); }
fn sync(s: *Session,db: *DB) !void { var p=Packet.init('S'); try tags(try send(s,db,&p),"Z"); }
fn startup(s: *Session, db: *DB) !void {
    const ssl="\x00\x00\x00\x08\x04\xd2\x16\x2f";
    const reply=try s.handle(db,ssl,&output); try check(reply.consumed == 8 and reply.written == 1 and output[0] == 'N' and !s.startup);
    const gss="\x00\x00\x00\x08\x04\xd2\x16\x30";
    const gss_reply=try s.handle(db,gss,&output); try check(gss_reply.written == 1 and output[0] == 'N');
    var p=Packet.init(0); p.len=4; p.number32(196608); p.string("user"); p.string("ramsql"); p.string("database"); p.string("test"); p.byte(0); put32(p.bytes[0..4],@intCast(p.len));
    for(0..p.len) |n| { const partial=try s.handle(db,p.bytes[0..n],&output); try check(partial.consumed == 0 and partial.written == 0 and !s.startup); }
    const ready=try s.handle(db,p.bytes[0..p.len],&output);
    try check(ready.consumed == p.len and s.startup and !ready.close);
    try tags(output[0..ready.written],"RSSSSSSSKZ");
}
fn parse(s: *Session,db: *DB,name: []const u8,source: []const u8,oids: []const u32) ![]const u8 {
    var p=Packet.init('P'); p.string(name); p.string(source); p.number16(@intCast(oids.len)); for(oids) |oid| p.number32(oid); return send(s,db,&p);
}
fn bind(s: *Session,db: *DB,name: []const u8,statement: []const u8,values: []const ?[]const u8,format: u16,result_format: u16) ![]const u8 {
    var p=Packet.init('B'); p.string(name); p.string(statement); p.number16(1); p.number16(format); p.number16(@intCast(values.len));
    for(values) |v| { if(v) |b| { p.number32(@intCast(b.len)); p.append(b); } else p.number32(0xffffffff); }
    p.number16(1); p.number16(result_format); return send(s,db,&p);
}
fn describe(s: *Session,db: *DB,kind: u8,name: []const u8) ![]const u8 { var p=Packet.init('D'); p.byte(kind); p.string(name); return send(s,db,&p); }
fn execute(s: *Session,db: *DB,name: []const u8,limit: u32) ![]const u8 { var p=Packet.init('E'); p.string(name); p.number32(limit); return send(s,db,&p); }
fn close(s: *Session,db: *DB,kind: u8,name: []const u8) ![]const u8 { var p=Packet.init('C'); p.byte(kind); p.string(name); return send(s,db,&p); }

fn normal() !void {
    var db: DB=.{}; var s: Session=.{}; try startup(&s,&db);
    try tags(try query(&s,&db,"CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, ok BOOLEAN)"),"CZ");
    try tags(try query(&s,&db,"INSERT INTO notes VALUES (1, 'hello', TRUE)"),"CZ");
    const selected=try query(&s,&db,"SELECT * FROM notes"); try tags(selected,"TDCZ");
    var frames: Frames=.{.bytes=selected}; const description=(try frames.next()).?;
    try check(description.body[0] == 0 and description.body[1] == 3);
    const row=(try frames.next()).?; try check(equal(row.body,"\x00\x03\x00\x00\x00\x011\x00\x00\x00\x05hello\x00\x00\x00\x01t"));
    try tags(try query(&s,&db,"SELECT * FROM notes WHERE id = 999"),"TCZ");
    try tags(try query(&s,&db," ; \t\n"),"IZ");
    const duplicate=try query(&s,&db,"INSERT INTO notes VALUES (1,'bad',FALSE)"); try tags(duplicate,"EZ"); try state(duplicate,"23505");
    try tags(try query(&s,&db,"SELECT body FROM notes"),"TDCZ"); try check(equal(s.result.rows[0].cells[0].text.slice(),"hello"));
    const missing=try query(&s,&db,"SELECT * FROM missing"); try state(missing,"42P01");
    try tags(try query(&s,&db,"BEGIN"),"CZ"); try check(db.status == 'T');
    try tags(try query(&s,&db,"DELETE FROM notes"),"CZ");
    try tags(try query(&s,&db,"ROLLBACK"),"CZ"); try check(db.status == 'I');
    try tags(try query(&s,&db,"SELECT * FROM notes"),"TDCZ");
    _=try query(&s,&db,"BEGIN"); _=try query(&s,&db,"SELECT * FROM missing"); try check(db.status == 'E');
    try state(try query(&s,&db,"SELECT * FROM notes"),"25P02"); _=try query(&s,&db,"ROLLBACK");
    try state(try query(&s,&db,"BEGIN; DELETE FROM notes"),"0A000"); try check(db.status == 'I');
    try state(try query(&s,&db,"COMMIT junk"),"0A000"); try check(db.status == 'I');
    var terminate=Packet.init('X'); const reply=try s.handle(&db,terminate.slice(),&output); try check(reply.close and reply.written == 0);
}
fn extended() !void {
    var db: DB=.{}; var s: Session=.{}; try startup(&s,&db);
    _=try query(&s,&db,"CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, ok BOOLEAN)");
    try tags(try parse(&s,&db,"insert","INSERT INTO notes VALUES ($1,$2,$3)",&.{20,25,16}),"1");
    try tags(try bind(&s,&db,"","insert",&.{"42","a'b; -- $1","t"},0,0),"2");
    try tags(try describe(&s,&db,'P',""),"n");
    try tags(try execute(&s,&db,"",0),"C"); try sync(&s,&db);
    try tags(try parse(&s,&db,"select","SELECT * FROM notes WHERE id = $1",&.{20}),"1");
    try tags(try describe(&s,&db,'S',"select"),"tT");
    try tags(try bind(&s,&db,"","select",&.{"\x00\x00\x00\x00\x00\x00\x00\x2a"},1,1),"2");
    const description=try describe(&s,&db,'P',""); try tags(description,"T");
    const result=try execute(&s,&db,"",0); try tags(result,"DC");
    var frames: Frames=.{.bytes=result}; const row=(try frames.next()).?;
    try check(u32be(row.body[2..6]) == 8 and equal(row.body[6..14],"\x00\x00\x00\x00\x00\x00\x00\x2a"));
    try check(equal(s.result.rows[0].cells[1].text.slice(),"a'b; -- $1"));
    try sync(&s,&db);
    try tags(try close(&s,&db,'S',"insert"),"3");
    try tags(try parse(&s,&db,"null","INSERT INTO notes VALUES ($1,$2,$3)",&.{20,25,16}),"1");
    try tags(try bind(&s,&db,"","null",&.{"-1",null,null},0,0),"2");
    try tags(try execute(&s,&db,"",0),"C"); try sync(&s,&db);
    try tags(try parse(&s,&db,"all","SELECT * FROM notes ORDER BY id",&.{}),"1");
    try tags(try bind(&s,&db,"","all",&.{},0,0),"2");
    try tags(try bind(&s,&db,"other","all",&.{},0,0),"2");
    try tags(try describe(&s,&db,'P',""),"T");
    try tags(try execute(&s,&db,"",1),"Ds");
    try check(s.active_portal != null);
    try tags(try close(&s,&db,'P',"other"),"3"); try check(s.active_portal != null);
    try tags(try execute(&s,&db,"",1),"DC"); try check(s.active_portal == null);
    try sync(&s,&db);
    try tags(try parse(&s,&db,"quoted","SELECT * FROM notes WHERE body = '$9' -- $7",&.{}),"1");
    try state(try parse(&s,&db,"all","SELECT * FROM notes",&.{}),"42P05");
    var ignored=Packet.init('P'); ignored.string(""); ignored.string("SELECT * FROM notes"); ignored.number16(0);
    try tags(try send(&s,&db,&ignored),""); try sync(&s,&db);
    try state(try bind(&s,&db,"","absent",&.{},0,0),"26000"); try sync(&s,&db);
    try state(try execute(&s,&db,"absent",0),"34000"); try sync(&s,&db);
}
fn inference() !void {
    var db: DB=.{}; var s: Session=.{}; try startup(&s,&db);
    _=try query(&s,&db,"CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT, ok BOOLEAN)");
    try tags(try parse(&s,&db,"insert","INSERT INTO t (body,id,ok) VALUES ($1,$2,$3)",&.{}),"1");
    try tags(try describe(&s,&db,'S',"insert"),"tn");
    try check(s.statements[0].oids[0] == 25 and s.statements[0].oids[1] == 20 and s.statements[0].oids[2] == 16);
    try tags(try bind(&s,&db,"","insert",&.{"123","7","true"},0,0),"2");
    try tags(try execute(&s,&db,"",0),"C"); try sync(&s,&db);
    try tags(try parse(&s,&db,"where","SELECT * FROM t WHERE body = $1 AND id = $2",&.{}),"1");
    try tags(try bind(&s,&db,"","where",&.{"123","7"},0,0),"2");
    try tags(try execute(&s,&db,"",0),"DC");
    try check(equal(s.result.rows[0].cells[1].text.slice(),"123")); try sync(&s,&db);
    try tags(try parse(&s,&db,"update","UPDATE t SET body = $1 WHERE id = $2",&.{}),"1");
    try tags(try bind(&s,&db,"","update",&.{"456","7"},0,0),"2");
    try tags(try execute(&s,&db,"",0),"C"); try sync(&s,&db);
    try tags(try parse(&s,&db,"mixed","INSERT INTO t VALUES ($1,$2,$3)",&.{21,0,16}),"1");
    try tags(try bind(&s,&db,"","mixed",&.{"\x00\x08","999","\x00"},1,0),"2");
    try tags(try execute(&s,&db,"",0),"C"); try sync(&s,&db);
    try tags(try query(&s,&db,"SELECT body FROM t ORDER BY id"),"TDDCZ");
    try check(equal(s.result.rows[0].cells[0].text.slice(),"456") and equal(s.result.rows[1].cells[0].text.slice(),"999"));
}
fn statementLifecycle() !void {
    var db: DB=.{}; var s: Session=.{}; try startup(&s,&db);
    _=try query(&s,&db,"CREATE TABLE t (id INTEGER)");
    for(0..24) |i| {
        var names: [32]u8=undefined; const name=try std.fmt.bufPrint(&names,"_pg3_{d}",.{i});
        try tags(try parse(&s,&db,name,"SELECT * FROM t",&.{}),"1");
        try tags(try bind(&s,&db,"",name,&.{},0,0),"2");
        try tags(try execute(&s,&db,"",0),"C"); try sync(&s,&db);
        if(i%2 == 0) {
            var sql_text: [128]u8=undefined;
            const dealloc=try std.fmt.bufPrint(&sql_text,"DEALLOCATE \"{s}\"",.{name});
            try tags(try query(&s,&db,dealloc),"CZ");
        } else try tags(try close(&s,&db,'S',name),"3");
    }
    try tags(try parse(&s,&db,"a","SELECT * FROM t",&.{}),"1");
    try tags(try parse(&s,&db,"b","SELECT * FROM t",&.{}),"1");
    try tags(try query(&s,&db,"DEALLOCATE PREPARE ALL;"),"CZ");
    for(s.statements) |statement| try check(!statement.live);
    try state(try query(&s,&db,"DEALLOCATE absent"),"26000");
    try tags(try parse(&s,&db,"c","SELECT * FROM t",&.{}),"1");
    try state(try query(&s,&db,"DEALLOCATE c; DROP TABLE t"),"42601");
    try tags(try close(&s,&db,'S',"c"),"3");
}
fn malformed() !void {
    var db: DB=.{}; var s: Session=.{}; try startup(&s,&db);
    var p=Packet.init('Q'); p.string("CREATE TABLE t (id INTEGER)"); const packet=p.slice();
    for(0..packet.len) |i| { const reply=try s.handle(&db,packet[0..i],&output); try check(reply.consumed == 0 and reply.written == 0); }
    var tiny: [8]u8=undefined;
    if(s.handle(&db,packet,&tiny)) |_| return error.SmallOutputAccepted else |err| try check(err == error.BufferTooSmall);
    try tags(try send(&s,&db,&p),"CZ");
    var nozero=Packet.init('Q'); nozero.append("SELECT * FROM t"); try state(try send(&s,&db,&nozero),"08P01");
    var extra=Packet.init('S'); extra.byte(0); try state(try send(&s,&db,&extra),"08P01"); try sync(&s,&db);
    var unknown=Packet.init('?'); try state(try send(&s,&db,&unknown),"0A000"); try sync(&s,&db);
    var bad=Packet.init('B'); bad.string(""); bad.string(""); bad.number16(0xffff); try state(try send(&s,&db,&bad),"26000"); try sync(&s,&db);
    try tags(try parse(&s,&db,"p","SELECT * FROM t WHERE id = $1",&.{20}),"1");
    try state(try bind(&s,&db,"","p",&.{"\x00"},1,0),"08P01"); try sync(&s,&db);
    try state(try bind(&s,&db,"","p",&.{"1; DROP TABLE t"},0,0),"42804"); try sync(&s,&db);
    try tags(try bind(&s,&db,"","p",&.{"1"},0,0),"2");
    try state(try execute(&s,&db,"",0xffffffff),"08P01"); try sync(&s,&db);
    try tags(try query(&s,&db,"SELECT * FROM t"),"TCZ");
    var invalid: [5]u8=.{ 'Q',0,0,0,3 }; const reply=try s.handle(&db,&invalid,&output); try check(reply.close); try state(output[0..reply.written],"08P01");
    var oversized: [5]u8=.{ 'Q',0x7f,0xff,0xff,0xff }; const big=try s.handle(&db,&oversized,&output); try check(big.close and big.consumed == 5);
    var s2: Session=.{}; const missing="\x00\x00\x00\x09\x00\x03\x00\x00\x00";
    const missing_reply=try s2.handle(&db,missing,&output); try check(missing_reply.close and !s2.startup);
}
fn fuzz() !void {
    var db: DB=.{}; var s: Session=.{}; s.startup=true;
    var seed: u32=0x52a70d33;
    var packet: [128]u8=undefined;
    for(0..4096) |case| {
        const length=5+case%123;
        for(packet[0..length]) |*b| { seed=seed*%1664525+%1013904223; b.*=@truncate(seed >> 24); }
        if(case%2 == 0) put32(packet[1..5],@intCast(length-1));
        s.failed=false;
        const reply=try s.handle(&db,packet[0..length],&output);
        try check(reply.consumed <= length and reply.written <= output.len);
        if(reply.written != 0) { var frames: Frames=.{.bytes=output[0..reply.written]}; while(try frames.next()) |_| {} }
        fuzz_inputs+=1;
    }
}
pub fn main(init: std.process.Init) !void {
    try normal(); try extended(); try inference(); try statementLifecycle(); try malformed(); try fuzz();
    var report: [256]u8=undefined;
    const line=try std.fmt.bufPrint(&report,"{{\"suite\":\"postgres\",\"pass\":true,\"assertions\":{d},\"packets\":{d},\"fuzz_inputs\":{d},\"session_bytes\":{d}}}\n",.{assertions,packets,fuzz_inputs,@sizeOf(Session)});
    try std.Io.File.stdout().writeStreamingAll(init.io,line);
}
