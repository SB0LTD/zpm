//! Research proof only: exact bag/NULL algebra for aggregate-before-join and
//! nested aggregation. This is not an integrated SQL execution path or a DB benchmark.
const std=@import("std");
const Error=error{Overflow,Workspace,Proof};
const keys=37;const groups=8;
const State=struct {rows:i128=0,nonnull:i128=0,sum:i128=0};
const Fact=struct {key:?u8,value:?i64,selected:bool};
const Dim=struct {key:?u8,category:?u8};
const Category=struct {key:?u8,group:?u8};
const Nested=struct {customers:i128=0,sales:i128=0,total:i128=0,max:?i128=null};
var assertions:usize=0;
var joined_rows:usize=0;
var factor_products:usize=0;
fn check(ok:bool) Error!void {assertions+=1;if(!ok) return error.Proof;}
fn plus(a:i128,b:i128) Error!i128 {const v=@addWithOverflow(a,b);if(v[1]!=0)return error.Overflow;return v[0];}
fn times(a:i128,b:i128) Error!i128 {const v=@mulWithOverflow(a,b);if(v[1]!=0)return error.Overflow;return v[0];}
fn add(a:State,b:State) Error!State {return .{.rows=try plus(a.rows,b.rows),.nonnull=try plus(a.nonnull,b.nonnull),.sum=try plus(a.sum,b.sum)};}
fn multiply(a:State,b:State) Error!State {return .{.rows=try times(a.rows,b.rows),.nonnull=try times(a.nonnull,b.nonnull),.sum=try times(a.sum,b.sum)};}
fn row(value:?i64) State {return .{.rows=1,.nonnull=@intFromBool(value!=null),.sum=value orelse 0};}
fn same(a:State,b:State) bool {return a.rows==b.rows and a.nonnull==b.nonnull and a.sum==b.sum;}
fn equal(a:?u8,b:?u8) bool {return a!=null and b!=null and a.?==b.?;}
fn dimensionDomain(dims:[]const Dim) Error!void {
    for(dims) |dim| if(dim.key) |key| {if(key>=keys) return error.Workspace;};
}

fn foldFacts(facts:[]const Fact,by_key:[]State) Error!void {
    if(by_key.len<keys) return error.Workspace;
    @memset(by_key,.{});
    for(facts) |fact| if(fact.selected) {if(fact.key) |key| if(key<keys) {by_key[key]=try add(by_key[key],row(fact.value));};};
}
fn contracted(facts:[]const Fact,dims:[]const Dim,categories:[]const Category,
    by_key:[]State,links:[]State,out:[]State) Error!usize {
    if(by_key.len<keys or links.len<keys*groups or out.len<groups) return error.Workspace;
    try dimensionDomain(dims);
    for(categories) |category| if(category.group) |group| {if(group>=groups-1) return error.Workspace;};
    try foldFacts(facts,by_key);@memset(links,.{});@memset(out,.{});
    const unit:State=.{.rows=1,.nonnull=1,.sum=1};
    // A production planner would build these links using indexes/hash joins.
    // Nested loops here deliberately keep the proof independent of an index.
    for(dims) |dim| if(dim.key) |key| {if(key<keys) for(categories) |category| {
        if(equal(dim.category,category.key)) {
            const group=category.group orelse groups-1;
            const index=@as(usize,key)*groups+group;
            links[index]=try add(links[index],unit);
        }
    };};
    var products:usize=0;
    for(by_key[0..keys],0..) |value,key| if(value.rows!=0) {
        for(out[0..groups],0..) |*group,g| if(links[key*groups+g].rows!=0) {
            group.*=try add(group.*,try multiply(value,links[key*groups+g]));products+=1;
        };
    };
    return products;
}
fn flattened(facts:[]const Fact,dims:[]const Dim,categories:[]const Category,out:*[groups]State) usize {
    out.*=@splat(.{});var matches:usize=0;
    for(facts) |fact| if(fact.selected) {for(dims) |dim| if(equal(fact.key,dim.key)) {
        for(categories) |category| if(equal(dim.category,category.key)) {
            const g=category.group orelse groups-1;matches+=1;
            out[g].rows+=1;if(fact.value) |value| {out[g].nonnull+=1;out[g].sum+=value;}
        };
    };};
    return matches;
}
fn nested(facts:[]const Fact,dims:[]const Dim,threshold:i128,by_key:[]State,out:*[groups]Nested) Error!void {
    try dimensionDomain(dims);
    try foldFacts(facts,by_key);out.*=@splat(.{});
    for(by_key[0..keys],0..) |value,key| {
        if(value.rows==0 or value.nonnull==0 or value.sum<=threshold) continue;
        for(dims) |dim| if(dim.key!=null and dim.key.?==key) {
            const g=if(dim.category) |code| code%(groups-1) else groups-1;
            out[g].customers+=1;out[g].sales+=value.rows;out[g].total+=value.sum;
            out[g].max=if(out[g].max) |m| @max(m,value.sum) else value.sum;
        };
    }
}
fn nestedOracle(facts:[]const Fact,dims:[]const Dim,threshold:i128,out:*[groups]Nested) void {
    out.*=@splat(.{});
    for(dims) |dim| {
        var count:i128=0;var nonnull:i128=0;var sum:i128=0;
        for(facts) |fact| if(fact.selected and equal(fact.key,dim.key)) {
            count+=1;if(fact.value) |value| {nonnull+=1;sum+=value;}
        };
        if(count==0 or nonnull==0 or sum<=threshold) continue;
        const g=if(dim.category) |code| code%(groups-1) else groups-1;
        out[g].customers+=1;out[g].sales+=count;out[g].total+=sum;
        out[g].max=if(out[g].max) |m| @max(m,sum) else sum;
    }
}
fn next(state:*u64) u64 {state.*=state.* *% 6364136223846793005 +% 1442695040888963407;return state.*>>24;}
var fixture_facts:[4099]Fact=undefined;
var fixture_dimensions:[97]Dim=undefined;
var fixture_categories:[29]Category=undefined;
var fixture_by_key:[keys]State=undefined;
var fixture_links:[keys*groups]State=undefined;
fn fixture(seed:u64) !void {
    var rng=seed+1;
    for(&fixture_facts) |*fact| {
        const key=next(&rng)%43;const amount=next(&rng)%2001;
        fact.*=.{.key=if(key==42) null else @intCast(key),
            .value=if(amount%13==0 or seed==3) null else @as(i64,@intCast(amount))-1000,
            .selected=seed!=4 and next(&rng)%11<5};
    }
    for(&fixture_dimensions) |*dim| {const a=next(&rng)%43;const b=next(&rng)%17;dim.*=.{.key=if(a==42)null else @intCast(a),.category=if(b==16)null else @intCast(b)};}
    for(&fixture_categories) |*category| {const a=next(&rng)%17;const b=next(&rng)%groups;category.*=.{.key=if(a==16)null else @intCast(a),.group=if(b==groups-1)null else @intCast(b)};}
    // Out-of-domain fact keys deliberately have no matching dimension.
    for(&fixture_dimensions) |*dim| if(dim.key!=null and dim.key.?>=keys) {dim.key=null;};
    var expected:[groups]State=undefined;var actual:[groups]State=undefined;
    const tuples=flattened(&fixture_facts,&fixture_dimensions,&fixture_categories,&expected);
    const products=try contracted(&fixture_facts,&fixture_dimensions,&fixture_categories,&fixture_by_key,&fixture_links,&actual);
    joined_rows+=tuples;factor_products+=products;
    for(expected,actual) |a,b| try check(same(a,b));
    for([_]i128{-50000,0,5000}) |threshold| {
        var wanted:[groups]Nested=undefined;var got:[groups]Nested=undefined;
        nestedOracle(&fixture_facts,&fixture_dimensions,threshold,&wanted);try nested(&fixture_facts,&fixture_dimensions,threshold,&fixture_by_key,&got);
        for(wanted,got) |a,b| try check(a.customers==b.customers and a.sales==b.sales and a.total==b.total and a.max==b.max);
    }
    if(seed==3) for(actual) |state| {try check(state.nonnull==0 and state.sum==0);};
    if(seed==4) try check(tuples==0 and products==0);
}
pub fn main() !void {
    const values=[_]?i64{null,-2,-1,0,1,2};
    for(values) |a| for(values) |b| for(values) |c| {
        const x=row(a);const y=row(b);const z=row(c);
        try check(same(try multiply(x,try add(y,z)),try add(try multiply(x,y),try multiply(x,z))));
        try check(same(try add(try add(x,y),z),try add(x,try add(y,z))));
        try check(same(try multiply(try multiply(x,y),z),try multiply(x,try multiply(y,z))));
    };
    if(plus(170141183460469231731687303715884105727,1)) |_| return error.Proof else |err| try check(err==error.Overflow);
    if(times(-170141183460469231731687303715884105728,-1)) |_| return error.Proof else |err| try check(err==error.Overflow);
    for(0..32) |seed| try fixture(seed);
    // NULL group identity must never collide with an ordinary encoded value.
    const two_facts=[_]Fact{.{.key=0,.value=10,.selected=true},.{.key=1,.value=20,.selected=true}};
    const two_dims=[_]Dim{.{.key=0,.category=7},.{.key=1,.category=null}};
    var separated:[groups]Nested=undefined;
    try nested(&two_facts,&two_dims,0,&fixture_by_key,&separated);
    try check(separated[0].customers==1 and separated[0].total==10 and separated[0].max==10);
    try check(separated[groups-1].customers==1 and separated[groups-1].total==20 and separated[groups-1].max==20);
    var unchanged:[groups]State=@splat(.{.rows=123,.nonnull=122,.sum=-321});
    if(contracted(&fixture_facts,&fixture_dimensions,&fixture_categories,fixture_by_key[0..keys-1],&fixture_links,&unchanged)) |_| return error.Proof else |err| try check(err==error.Workspace);
    for(unchanged) |value| try check(value.rows==123 and value.nonnull==122 and value.sum == -321);
    const outside=[_]Dim{.{.key=keys,.category=0}};
    if(contracted(&fixture_facts,&outside,&fixture_categories,&fixture_by_key,&fixture_links,&unchanged)) |_| return error.Proof else |err| try check(err==error.Workspace);
    for(unchanged) |value| try check(value.rows==123 and value.nonnull==122 and value.sum == -321);
    const null_alias=[_]Category{.{.key=0,.group=groups-1}};
    if(contracted(&fixture_facts,&fixture_dimensions,&null_alias,&fixture_by_key,&fixture_links,&unchanged)) |_| return error.Proof else |err| try check(err==error.Workspace);
    for(unchanged) |value| try check(value.rows==123 and value.nonnull==122 and value.sum == -321);
    std.debug.print("PASS factor algebra: {d} assertions; flat joined rows={d}, factor products={d}; excludes scan/link-build costs; research prototype, SQL integration=false\n",.{assertions,joined_rows,factor_products});
}
