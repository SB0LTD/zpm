//! LIKE/ILIKE ESCAPE: direct UTF-8 patterns and constant-space reference DP.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=4,.columns=8,.rows_per_table=16,.text_bytes=256,.nulls_first_ascending=false});
var db:DB=.{};var r:DB.Result=.{};var assertions:usize=0;var digest:u64=14695981039346656037;
fn check(ok:bool) !void {assertions+=1;if(!ok)return error.LikeEscapeContractFailed;}
fn truth(source:[]const u8,wanted:?bool) !void {
    db.execute(source,&r) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};
    try check(r.row_count==1 and r.column_count==1 and r.column_types[0]==.boolean);
    const cell=r.rows[0].cells[0];if(wanted)|b|try check(cell==.boolean and cell.boolean==b) else try check(cell==.null_value);
}
fn scalar(source:[]const u8,wanted:i64) !void {db.execute(source,&r) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};try check(r.row_count==1 and r.rows[0].cells[0]==.integer and r.rows[0].cells[0].integer==wanted);}
fn booleans(source:[]const u8,wanted:[]const ?bool) !void {
    db.execute(source,&r) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};try check(r.column_count==1 and r.row_count==wanted.len and r.column_types[0]==.boolean);
    for(wanted,0..)|value,index|{const cell=r.rows[index].cells[0];if(value)|b|try check(cell==.boolean and cell.boolean==b) else try check(cell==.null_value);}
}
fn mutate(source:[]const u8,wanted:usize) !void {db.execute(source,&r) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};try check(r.affected_rows==wanted);}
fn rejects(source:[]const u8,wanted:anyerror) !void {
    const before=r;
    if(db.execute(source,&r)) |_| return error.InvalidMembershipAccepted else |err| {if(err!=wanted)std.debug.print("{s}: {s}\n",.{source,@errorName(err)});try check(err==wanted);}
    try check(r.row_count==before.row_count and r.column_count==before.column_count);
    for(0..r.row_count)|row|for(0..r.column_count)|column|try check(std.meta.eql(r.rows[row].cells[column],before.rows[row].cells[column]));
}
const Token=struct {source:[]const u8,literal:[]const u8="",kind:enum{literal,one,many}=.literal};
fn lower(byte:u8) u8 {return if(byte>='A' and byte<='Z')byte+32 else byte;}
fn same(a:[]const u8,b:[]const u8,insensitive:bool) bool {if(a.len!=b.len)return false;for(a,b)|x,y|if((if(insensitive)lower(x) else x)!=(if(insensitive)lower(y) else y))return false;return true;}
fn reference(text:[]const u8,tokens:[]const Token,insensitive:bool) bool {
    var points:[8][]const u8=undefined;var count:usize=0;var at:usize=0;
    while(at<text.len){const width:usize=if(text[at]<128)1 else if(text[at]<224)2 else if(text[at]<240)3 else 4;points[count]=text[at..][0..width];count+=1;at+=width;}
    var current:[9]bool=@splat(false);current[0]=true;
    for(tokens)|token|{var next:[9]bool=@splat(false);switch(token.kind){
        .literal=>for(0..count)|i|{next[i+1]=current[i] and same(points[i],token.literal,insensitive);},
        .one=>for(0..count)|i|{next[i+1]=current[i];},
        .many=>{var seen=false;for(0..count+1)|i|{seen=seen or current[i];next[i]=seen;}},
    }current=next;}
    return current[count];
}
fn hashByte(byte:u8) void {digest=(digest^byte)*%1099511628211;}
fn matrix() !void {
    const texts=[_][]const u8{"","a","A","aa","ab","a_b","é","éa","🧵","_"};
    const escapes=[_][]const u8{"","!","\\","é","🧵"};
    var escaped:[8]u8=undefined;var pattern:[32]u8=undefined;var source:[256]u8=undefined;
    for(escapes)|escape|{
        const underscore=try std.fmt.bufPrint(&escaped,"{s}_",.{escape});
        const tokens=[_]Token{.{.source="a",.literal="a"},.{.source="A",.literal="A"},.{.source=if(std.mem.eql(u8,escape,"é"))"éé" else "é",.literal="é"},.{.source="%",.kind=.many},.{.source="_",.kind=.one},.{.source=underscore,.literal="_"}};
        const available:usize=if(escape.len==0)5 else 6;
        for(0..3)|length|for(0..if(length==0)1 else available)|first|for(0..if(length<2)1 else available)|second|{
            var selected:[2]Token=undefined;var used:usize=0;
            if(length>0){selected[0]=tokens[first];@memcpy(pattern[used..][0..selected[0].source.len],selected[0].source);used+=selected[0].source.len;}
            if(length>1){selected[1]=tokens[second];@memcpy(pattern[used..][0..selected[1].source.len],selected[1].source);used+=selected[1].source.len;}
            for(texts)|text|for([_]bool{false,true})|insensitive|for([_]bool{false,true})|negated|{
                const query=try std.fmt.bufPrint(&source,"SELECT '{s}' {s}{s} '{s}' ESCAPE '{s}'",.{text,if(negated)"NOT " else "",if(insensitive)"ILIKE" else "LIKE",pattern[0..used],escape});
                const wanted=reference(text,selected[0..length],insensitive)!=negated;
                for(query)|byte|hashByte(byte);hashByte(@intFromBool(wanted));try truth(query,wanted);
            };
        };
    }
}
var polls:usize=0;
fn cancelLater(_: ?*anyopaque) sql.Error!void {polls+=1;if(polls==32)return error.QueryCanceled;}
fn atCapacity() !void {
    const Tiny=sql.Database(.{.tables=1,.columns=1,.rows_per_table=1,.text_bytes=8});
    var tiny:Tiny=.{};var output:Tiny.Result=.{};var source:[96]u8=undefined;
    const slashes=[_]u8{'\\'}**8;
    const query=try std.fmt.bufPrint(&source,"SELECT '{s}' LIKE '{s}' ESCAPE ''",.{slashes,slashes});
    try tiny.execute(query,&output);try check(output.row_count==1 and output.rows[0].cells[0].boolean);
}
pub fn main(init:std.process.Init) !void {
    try matrix();
    try truth("SELECT 'a_b' LIKE 'a!_b' ESCAPE '!'",true);
    try truth("SELECT 'a%b' NOT LIKE 'a!%b' ESCAPE '!'",false);
    try truth("SELECT 'A_B' ILIKE 'a!_b' ESCAPE '!'",true);
    try truth("SELECT '%' LIKE '%%' ESCAPE '%'",true);
    try truth("SELECT '_' LIKE '__' ESCAPE '_'",true);
    try truth("SELECT '!' LIKE '!!' ESCAPE '!'",true);
    try truth("SELECT '🧵' LIKE '🧵🧵' ESCAPE '🧵'",true);
    try truth("SELECT 'a_b' LIKE 'a🧵_b' ESCAPE '🧵'",true);
    try truth("SELECT 'a_b' LIKE 'a''_b' ESCAPE ''''",true);
    try truth("SELECT 'a\\b' LIKE 'a\\b' ESCAPE ''",true);
    try truth("SELECT 'ab' LIKE 'a\\b'",true);
    try truth("SELECT '' LIKE '!' ESCAPE '!'",false);
    try truth("SELECT 'a' LIKE 'a!' ESCAPE '!'",false);
    try truth("SELECT 'x' LIKE 'a!' ESCAPE '!'",false);
    try rejects("SELECT 'a!' LIKE 'a!' ESCAPE '!'",error.InvalidEscapeSequence);
    try rejects("SELECT 'a' LIKE '%_!' ESCAPE '!'",error.InvalidEscapeSequence);
    try rejects("SELECT 'a' LIKE '%' ESCAPE '%'",error.InvalidEscapeSequence);
    try rejects("SELECT 'a' LIKE 'a' ESCAPE 'xx'",error.InvalidEscapeSequence);
    try rejects("SELECT 'a' LIKE 'a' ESCAPE 'é'",error.InvalidEscapeSequence);
    try rejects("SELECT NULL LIKE 'a' ESCAPE 'xx'",error.InvalidEscapeSequence);
    try truth("SELECT NULL LIKE NULL ESCAPE 'xx'",null);
    try truth("SELECT 'a' LIKE 'a' ESCAPE NULL",null);
    try truth("SELECT 'a' LIKE 'a' ESCAPE 'x'::name",true);
    try rejects("SELECT 'a' LIKE 'a' ESCAPE 1",error.UndefinedFunction);
    try db.execute("CREATE SEQUENCE ls",&r);
    try truth("SELECT nextval('ls')::text LIKE nextval('ls')::text ESCAPE nextval('ls')::text",false);
    try scalar("SELECT currval('ls')",3);
    try db.execute("CREATE TABLE lt(id INT PRIMARY KEY,v TEXT,p TEXT,e TEXT)",&r);
    try db.execute("INSERT INTO lt VALUES(1,'a_b','a!_b','!'),(2,'a%b','a!%b','!'),(3,NULL,'a','!'),(4,'abc','A%','!'),(5,'a\\b','a\\b',''),(6,'🧵','_','!'),(7,'a','a',NULL),(8,NULL,'a','xx'),(9,'a',NULL,'xx')",&r);
    try booleans("SELECT v LIKE p ESCAPE e FROM lt WHERE id<=7 ORDER BY id",&.{true,true,null,false,true,true,null});
    try truth("SELECT v ILIKE p ESCAPE e FROM lt WHERE id=4",true);
    try rejects("SELECT v LIKE p ESCAPE e FROM lt WHERE id=8",error.InvalidEscapeSequence);
    try truth("SELECT v LIKE p ESCAPE e FROM lt WHERE id=9",null);
    try truth("SELECT v LIKE nextval('ls')::text ESCAPE nextval('ls')::text FROM lt WHERE id=3",null);
    try scalar("SELECT currval('ls')",5);
    try truth("SELECT v LIKE p ESCAPE nextval('ls')::text FROM lt WHERE id=9",null);
    try scalar("SELECT currval('ls')",6);
    try truth("SELECT v LIKE nextval('ls')::text ESCAPE e FROM lt WHERE id=7",null);
    try scalar("SELECT currval('ls')",7);
    try scalar("SELECT COUNT(*) FROM lt WHERE v LIKE 'a!_%' ESCAPE '!'",1);
    try scalar("SELECT COUNT(*) FROM lt x JOIN (SELECT p,e FROM lt WHERE id=1) y ON x.v LIKE y.p ESCAPE y.e",1);
    try truth("SELECT MAX(v) LIKE 'a!_%' ESCAPE e FROM lt WHERE id=1 GROUP BY e",true);
    try booleans("SELECT v LIKE p ESCAPE e FROM lt WHERE id<=2 GROUP BY v LIKE p ESCAPE e",&.{true});
    try mutate("UPDATE lt SET v='matched' WHERE v LIKE 'a!_%' ESCAPE '!'",1);
    try rejects("UPDATE lt SET v='bad' WHERE v LIKE p ESCAPE e",error.InvalidEscapeSequence);
    try scalar("SELECT COUNT(*) FROM lt WHERE v='bad'",0);
    try mutate("DELETE FROM lt WHERE v LIKE 'a!%%' ESCAPE '!'",1);
    var primary:DB=.{};var replayed:DB=.{};var scratch:DB.ReplayScratch=.{};
    var bytes:[32768]u8=undefined;var used:usize=0;
    try primary.executeChanges("CREATE TABLE g(id INT PRIMARY KEY,v TEXT,p TEXT,e TEXT,matched BOOLEAN GENERATED ALWAYS AS(v ILIKE p ESCAPE e) STORED,def BOOLEAN DEFAULT('a_b' LIKE 'a!_b' ESCAPE '!'))",&r,&bytes,&used,null,null);
    try replayed.applyChangeRecord(bytes[0..used],&scratch);
    try replayed.execute("INSERT INTO g(id,v,p,e) VALUES(1,'A_B','a!_b','!'),(2,NULL,'x','!')",&r);
    try replayed.execute("SELECT matched,def FROM g ORDER BY id",&r);
    try check(r.row_count==2 and r.rows[0].cells[0].boolean and r.rows[1].cells[0]==.null_value and r.rows[0].cells[1].boolean and r.rows[1].cells[1].boolean);
    try scalar("SELECT 17",17);
    const expensive="SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' LIKE '%aaaaaaaaaaaaaaaaaaaaaaaaab' ESCAPE '!'";
    var control:sql.ExecutionControl=.{.max_work=25};db.session.control=&control;
    try rejects(expensive,error.QueryWorkLimit);try check(control.used==25);
    var tail:sql.ExecutionControl=.{.max_work=25};db.session.control=&tail;
    try rejects("SELECT '' LIKE '%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%' ESCAPE '!'",error.QueryWorkLimit);try check(tail.used==25);
    var interrupt:sql.ExecutionControl=.{.poll=cancelLater,.poll_interval=1};db.session.control=&interrupt;
    try rejects(expensive,error.QueryCanceled);try check(polls==32);db.session.control=null;
    try atCapacity();
    var buffer:[192]u8=undefined;const report=try std.fmt.bufPrint(&buffer,"{{\"suite\":\"sql-like-escape\",\"pass\":true,\"assertions\":{d},\"matrix_queries\":8120,\"matrix_fnv64\":\"{x}\"}}\n",.{assertions,digest});
    try std.Io.File.stdout().writeStreamingAll(init.io,report);
}
