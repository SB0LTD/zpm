//! Caller-owned PostgreSQL temporal to_char templates. No heap or shared state.
//! Supported tokens are listed in docs/SQL_REPORTING_GAPS.md. Other known
//! formatting tokens fail explicitly; ordinary non-template bytes are literals.
const temporal=@import("temporal.sig");
const types=@import("types.sig");
const Error=types.Error;

const Writer=struct {
    output:?[]u8=null,at:usize=0,
    fn byte(self:*Writer,c:u8) Error!void {
        if(self.at==~@as(usize,0)) return error.TextCapacity;
        if(self.output) |out| {if(self.at==out.len) return error.TextCapacity;out[self.at]=c;}
        self.at+=1;
    }
    fn text(self:*Writer,s:[]const u8) Error!void {for(s) |c| try self.byte(c);}
    fn number(self:*Writer,n:u64,width:usize) Error!void {
        var digits:[20]u8=undefined;var at:usize=digits.len;var value=n;
        while(true){at-=1;digits[at]=@intCast('0'+value%10);value/=10;if(value==0) break;}
        var padding=width;while(padding>digits.len-at):(padding-=1) try self.byte('0');
        try self.text(digits[at..]);
    }
};
fn upper(c:u8) u8 {return if(c>='a' and c<='z') c-32 else c;}
fn matches(s:[]const u8,token:[]const u8) bool {
    if(s.len<token.len) return false;
    for(s[0..token.len],token) |a,b| if(a!=b) return false;
    return true;
}
fn name(out:*Writer,s:[]const u8,token:[]const u8,pad:bool) Error!void {
    const lower_case=token[0]>='a' and token[0]<='z';
    const title=token.len>1 and token[1]>='a' and token[1]<='z' and !lower_case;
    for(s,0..) |c,i| try out.byte(if(lower_case or (title and i!=0)) (if(c>='A' and c<='Z') c+32 else c) else upper(c));
    if(pad) {var n=s.len;while(n<9):(n+=1) try out.byte(' ');}
}
const months=[_] []const u8{"January","February","March","April","May","June","July","August","September","October","November","December"};
const days=[_] []const u8{"Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"};
// Longest before shortest. PostgreSQL recognizes upper/lower spellings, plus
// title-case names; arbitrary mixed-case template letters are literal text.
const tokens=[_] []const u8{"HH24","hh24","HH12","hh12","MONTH","Month","month","YYYY","yyyy","Y,YYY","y,yyy",
    "A.M.","a.m.","P.M.","p.m.","B.C.","b.c.","A.D.","a.d.","SSSSS","sssss","SSSS","ssss",
    "YYY","yyy","DDD","ddd","DAY","Day","day","MON","Mon","mon","HH","hh","MI","mi","SS","ss","MS","ms","US","us",
    "YY","yy","MM","mm","DD","dd","DY","Dy","dy","WW","ww","CC","cc","AM","am","PM","pm","BC","bc","AD","ad",
    "Y","y","D","d","W","w","Q","q","J","j"};
const unsupported=[_] []const u8{"IYYY","iyyy","IYY","iyy","IY","iy","IDDD","iddd","ID","id","IW","iw","I","i","TZH","TZM","TZ","tz","OF","RM","rm","TM","tm","FX","fx","SP","sp"};

fn render(us:i64,pattern:[]const u8,out:*Writer) Error!void {
    const date=@divFloor(us,temporal.usecs_per_day);const time=@mod(us,temporal.usecs_per_day);
    const civil=temporal.civilOf(date);const year:u64=@intCast(if(civil.year>0) civil.year else 1-civil.year);
    const month:u64=@intCast(civil.month);const day:u64=@intCast(civil.day);
    const hour:u64=@intCast(@divFloor(time,temporal.usecs_per_hour));
    const minute:u64=@intCast(@mod(@divFloor(time,temporal.usecs_per_minute),60));
    const second:u64=@intCast(@mod(@divFloor(time,temporal.usecs_per_second),60));
    const micro:u64=@intCast(@mod(time,temporal.usecs_per_second));
    const weekday:u64=@intCast(@mod(date+6,7));
    const doy:u64=@intCast(date-temporal.dateOf(civil.year,1,1)+1);
    var at:usize=0;
    while(at<pattern.len) {
        if(pattern[at]=='"') {
            at+=1;while(at<pattern.len and pattern[at]!='"') {
                if(pattern[at]=='\\' and at+1<pattern.len) at+=1;
                try out.byte(pattern[at]);at+=1;
            }
            if(at<pattern.len) at+=1;continue;
        }
        if(pattern[at]=='\\' and at+1<pattern.len and (pattern[at+1]=='"' or pattern[at+1]=='\\')) {
            at+=1;try out.byte(pattern[at]);at+=1;continue;
        }
        var fill=false;
        if(matches(pattern[at..],"FM") or matches(pattern[at..],"fm")) {fill=true;at+=2;if(at==pattern.len) break;}
        if(pattern.len-at>=3 and (matches(pattern[at..],"FF") or matches(pattern[at..],"ff")) and pattern[at+2]>='1' and pattern[at+2]<='6') {
            const width:usize=pattern[at+2]-'0';var value=micro;var n:usize=6;while(n>width):(n-=1) value/=10;
            try out.number(value,width);at+=3;continue;
        }
        var found:?[]const u8=null;for(tokens) |token| if(matches(pattern[at..],token)) {found=token;break;};
        if(found) |token| {
            const a=upper(token[0]);const b=if(token.len>1) upper(token[1]) else 0;
            var value:u64=0;var width:usize=1;var numeric=true;
            if(a=='Y') {value=if(token.len==1) year%10 else if(token.len==2) year%100 else if(token.len==3) year%1000 else year;width=token.len;
                if(token.len==5){try out.number(year/1000,1);try out.byte(',');value=year%1000;width=3;}}
            else if(a=='M' and b=='M'){value=month;width=2;}
            else if(a=='M' and b=='I'){value=minute;width=2;}
            else if(a=='M' and b=='S'){value=micro/1000;width=3;}
            else if(a=='U'){value=micro;width=6;}
            else if(a=='D' and b=='D'){value=if(token.len==3) doy else day;width=token.len;}
            else if(a=='D' and token.len==1) value=weekday+1
            else if(a=='W'){value=if(token.len==2) (doy-1)/7+1 else (day-1)/7+1;width=token.len;}
            else if(a=='Q') value=(month-1)/3+1
            else if(a=='J') value=@intCast(date+2451545)
            else if(a=='C'){value=(year-1)/100+1;width=2;if(civil.year<=0) try out.byte('-');}
            else if(a=='H'){value=if(token.len==4 and token[2]=='2') hour else if(hour%12==0) 12 else hour%12;width=2;}
            else if(a=='S'){value=if(token.len>2) @intCast(@divFloor(time,temporal.usecs_per_second)) else second;width=if(token.len>2) 1 else 2;}
            else {numeric=false;
                if(a=='M') try name(out,if(token.len==3) months[month-1][0..3] else months[month-1],token,token.len==5 and !fill)
                else if(a=='D') try name(out,if(b=='Y') days[weekday][0..3] else days[weekday],token,b=='A' and !fill)
                else {
                    const era=a=='B' or (a=='A' and (b=='D' or (token.len==4 and upper(token[2])=='D')));
                    const first:u8=if(era) (if(civil.year<=0) 'B' else 'A') else (if(hour<12) 'A' else 'P');
                    const lower_case=token[0]>='a' and token[0]<='z';
                    try out.byte(if(lower_case) first+32 else first);if(token.len==4) try out.byte('.');
                    try out.byte(if(era) (if(civil.year<=0) (if(lower_case) @as(u8,'c') else 'C') else (if(lower_case) @as(u8,'d') else 'D')) else (if(lower_case) @as(u8,'m') else 'M'));
                    if(token.len==4) try out.byte('.');
                }
            }
            if(numeric) try out.number(value,if(fill and !(a=='U' or (a=='M' and b=='S'))) 1 else width);
            at+=token.len;
            if(matches(pattern[at..],"TH") or matches(pattern[at..],"th")) {
                if(!numeric) return error.InvalidParameterValue;
                const suffix:[]const u8=if(value%100>=11 and value%100<=13) "TH" else switch(value%10){1=>"ST",2=>"ND",3=>"RD",else=>"TH"};
                for(suffix) |c| try out.byte(if(pattern[at]=='t') c+32 else c);at+=2;
            }
        } else {
            for(unsupported) |token| if(matches(pattern[at..],token)) return error.UnsupportedStatement;
            try out.byte(pattern[at]);at+=1;
        }
    }
}

/// Finite local timestamp input; preflight ensures errors never partially write.
pub fn format(us:i64,pattern:[]const u8,output:[]u8) Error!usize {
    if(!temporal.validTimestamp(us)) return error.DatetimeFieldOverflow;
    if(pattern.len!=0 and output.len!=0) {
        const a=@intFromPtr(pattern.ptr);const b=@intFromPtr(output.ptr);
        if((a<=b and b-a<pattern.len) or (b<a and a-b<output.len)) return error.InvalidParameterValue;
    }
    var check:Writer=.{};try render(us,pattern,&check);
    if(check.at>output.len) return error.TextCapacity;
    var out:Writer=.{.output=output};try render(us,pattern,&out);return out.at;
}
