// Fixed-storage regressions for JavaScript semantics used by BotGuard.
// The caller supplies reporting; this shared suite has no platform dependency.
const jsvm = @import("root.sig");
const compiler = @import("compiler.sig");
const values = @import("values.sig");

const Case = struct { name: []const u8, source: []const u8, expected: f64 };
const cases = [_]Case{
    // Shrinking must discard elements, including when length uses a computed key.
    .{ .name = "computed-length-shrink", .source = "var R;var a=[1,2,3,4,5];var k='length';a[k]=2;R=a.length*100+a[1]*10+(a[2]===undefined?1:0);", .expected = 221 },
    .{ .name = "computed-length-grow", .source = "var R;var a=[7];a['length']=4;R=a.length*100+a[0]*10+(a[3]===undefined?1:0);", .expected = 471 },
    .{ .name = "shrink-grow-clears-discarded-values", .source = "var R;var a=[11,22,33,44];a['length']=1;a['length']=4;R=a[0]+(a[1]===undefined?100:0)+(a[3]===undefined?1000:0);", .expected = 1111 },
    .{ .name = "grow-does-not-expose-neighbour-storage", .source = "var R;var a=[1];var b=[71,72,73,74];a['length']=128;a[127]=99;R=(a[1]===undefined?10000:0)+a[127]*100+b[0]+b[3];", .expected = 20045 },
    .{ .name = "computed-length-assignment-result", .source = "var R;var a=[1,2,3];var n=(a['length']=1);R=n*10+a.length;", .expected = 11 },
    // for-in sees inherited enumerable keys, suppresses duplicates, and honours
    // a non-enumerable own property shadowing an enumerable prototype property.
    .{ .name = "for-in-inherited-enumerable", .source = "var R;var p={inherited:2};var o=Object.create(p);o.own=3;var sum=0,n=0;for(var k in o){sum+=o[k];n++;}R=n*100+sum;", .expected = 205 },
    .{ .name = "for-in-prototype-chain-and-shadow", .source = "var R;var a={x:1,z:3};var b=Object.create(a);b.y=2;var o=Object.create(b);o.x=10;var sum=0,n=0;for(var k in o){sum+=o[k];n++;}R=n*100+sum;", .expected = 315 },
    .{ .name = "for-in-nonenumerable-own-shadow", .source = "var R;var p={hidden:9,visible:2};var o=Object.create(p);Object.defineProperty(o,'hidden',{value:7,enumerable:false});o.own=3;var n=0,sum=0;for(var k in o){n++;sum+=o[k];}R=n*100+sum;", .expected = 205 },
    .{ .name = "for-in-defineproperty-default-hidden", .source = "var R;var o={a:1};Object.defineProperty(o,'b',{value:2});var n=0;for(var k in o)n++;R=n;", .expected = 1 },
    .{ .name = "for-in-function-prototype-constructor-hidden", .source = "var R;function C(){}C.prototype.x=7;var o=new C();var n=0,sum=0;for(var k in o){n++;sum+=o[k];}R=n*10+sum;", .expected = 17 },
    // Literal replacement replaces the first match and implements the string
    // substitution tokens independently of regex support.
    .{ .name = "replace-first-literal-match", .source = "var R;R=('aba'.replace('a','X')==='Xba'?1:0);", .expected = 1 },
    .{ .name = "replace-no-match", .source = "var R;R=('abc'.replace('z','X')==='abc'?1:0);", .expected = 1 },
    .{ .name = "replace-empty-search", .source = "var R;R=('abc'.replace('','X')==='Xabc'?1:0);", .expected = 1 },
    .{ .name = "replace-substitution-dollar", .source = "var R;R=('abc'.replace('b','$$')==='a$c'?1:0);", .expected = 1 },
    .{ .name = "replace-substitution-match", .source = "var R;R=('abc'.replace('b','[$&]')==='a[b]c'?1:0);", .expected = 1 },
    .{ .name = "replace-substitution-prefix-suffix", .source = "var R;R=('abc'.replace('b',\"$`-$'\")==='aa-cc'?1:0);", .expected = 1 },
    .{ .name = "replace-substitution-missing-capture-literal", .source = "var R;R=('abc'.replace('b','$1:$0')==='a$1:$0c'?1:0);", .expected = 1 },
    .{ .name = "replace-callback-arguments", .source = "var R;var s='abc'.replace('b',function(m,i,s){return m+i+s.length;});R=(s==='ab13c'?1:0);", .expected = 1 },
    .{ .name = "replace-callback-called-once", .source = "var R=0;'aba'.replace('a',function(m,i,s){R++;return 'X';});", .expected = 1 },
    .{ .name = "replace-callback-result-dollar-is-literal", .source = "var R;var s='abc'.replace('b',function(){return '$&';});R=(s==='a$&c'?1:0);", .expected = 1 },
    // A local named eval must still call the intrinsic when its value is eval.
    // A shadowing user function must retain ordinary call semantics.
    .{ .name = "direct-eval-local-eval-binding", .source = "var R;(function(eval){var x=7;R=eval('x+2');})(eval);", .expected = 9 },
    .{ .name = "direct-eval-local-var-named-eval", .source = "var R;(function(){var eval=globalThis.eval;var x=8;R=eval('x+3');})();", .expected = 11 },
    .{ .name = "eval-shadowed-by-user-function", .source = "var R;(function(eval){var x=7;R=eval('x+2');})(function(s){return s.length;});", .expected = 3 },
    .{ .name = "eval-uses-first-argument", .source = "var R;R=eval('7','9');", .expected = 7 },
    .{ .name = "eval-nonstring-first-argument", .source = "var R;R=eval(7,'9');", .expected = 7 },
    .{ .name = "direct-eval-nested-enclosing-upvalue", .source = "var R;(function(){var x=31;function mid(){return function(){return eval('x+11');};}R=mid()();})();", .expected = 42 },
    .{ .name = "direct-eval-mutates-enclosing-upvalue", .source = "var R;(function(){var x=5;function make(){return function(){eval('x=17');};}var f=make();f();R=x;})();", .expected = 17 },
    .{ .name = "nested-direct-eval-read-and-write", .source = "var R;(function(){var x=10;function mid(){var y=2;return function(){return eval(\"eval('x=x+y');x\");};}R=mid()();})();", .expected = 12 },
    .{ .name = "nested-direct-eval-enclosing-read", .source = "var R;(function(){var x=10;return function(){R=eval(\"eval('x')\");};})()();", .expected = 10 },
    .{ .name = "nested-direct-eval-local-read", .source = "var R;(function(){var x=10;R=eval(\"eval('x')\");})();", .expected = 10 },
    .{ .name = "nested-direct-eval-two-enclosing-scopes", .source = "var R;(function(){var x=10;function mid(){var y=2;return function(){return eval(\"eval('x+y')\");};}R=mid()();})();", .expected = 12 },
    .{ .name = "nested-direct-eval-declared-local", .source = "var R;(function(){R=eval(\"var x=23;eval('x')\");})();", .expected = 23 },
    .{ .name = "nested-direct-eval-local-shadow", .source = "var R;(function(){var x=10;R=eval(\"var x=23;eval('x')\");})();", .expected = 23 },
    // Escaped grandchildren and siblings must share the original mutable cell.
    .{ .name = "transitive-mutable-closure-cell", .source = "var R;function outer(){var x=3;function mid(){return {get:function(){return x;},set:function(v){x=v;}};}return {cell:mid(),get:function(){return x;}};}var o=outer();o.cell.set(42);R=o.cell.get()+o.get();", .expected = 84 },
    .{ .name = "transitive-sibling-cells-stay-shared", .source = "var R;function outer(){var x=1;function mid(){return function(){return ++x;};}return [mid(),mid()];}var a=outer();R=a[0]()*100+a[1]()*10+a[0]();", .expected = 234 },
    .{ .name = "transitive-cells-independent-per-invocation", .source = "var R;function outer(n){var x=n;function mid(){return function(){return ++x;};}return mid();}var a=outer(10),b=outer(20);R=a()*100+b()*10+a();", .expected = 1322 },
    // Direct eval inherits the active call receiver, including nested eval and
    // constructor calls. Bare indirect eval continues to use the global object.
    .{ .name = "direct-eval-method-this", .source = "var R;var o={x:17,f:function(){return eval('this.x');}};R=o.f();", .expected = 17 },
    .{ .name = "direct-eval-call-this", .source = "var R;function f(){return eval('this.x');}R=f.call({x:23});", .expected = 23 },
    .{ .name = "nested-direct-eval-method-this", .source = "var R;var o={x:29,f:function(){return eval(\"eval('this.x')\");}};R=o.f();", .expected = 29 },
    .{ .name = "direct-eval-constructor-this", .source = "var R;function C(){eval('this.x=37');}R=(new C()).x;", .expected = 37 },
    .{ .name = "indirect-eval-keeps-global-this", .source = "var R;var x=41;var o={x:99,f:function(){var e=eval;return e('this.x');}};R=o.f();", .expected = 41 },
    .{ .name = "indirect-eval-keeps-global-bindings", .source = "var R;var x=50;(function(){var x=7;var e=eval;R=e('x');})();", .expected = 50 },
    .{ .name = "direct-eval-does-not-overwrite-global-shadow", .source = "var R;var x=50;(function(){var x=7;eval('x');var e=eval;R=e('x');})();", .expected = 50 },
    .{ .name = "return-does-not-publish-local-function", .source = "var R;var g=50;function outer(){function g(){return 7;}return eval('g()');}var v=outer();R=v*100+g;", .expected = 750 },
    .{ .name = "eval-function-declaration-shares-var-binding", .source = "var R;(function(){var g;function g(){return 7;}R=eval('g()')*10+g();})();", .expected = 77 },
    .{ .name = "return-does-not-publish-local-object", .source = "var R;var x=50;function outer(){var x={value:7};return eval('x.value');}var v=outer();R=v*100+x;", .expected = 750 },
    .{ .name = "escaped-eval-closure-keeps-local-object-private", .source = "var R;var f=50;function maker(){var f={x:7};return eval('(function(){return eval(\"f.x\");})');}var g=maker();R=g()*100+f;", .expected = 750 },
    .{ .name = "function-constructor-keeps-global-bindings", .source = "var R;var x=50;(function(){var x=7;R=Function('return x')();})();", .expected = 50 },
    .{ .name = "function-constructor-parameters", .source = "var R;R=Function('a','b','return a*10+b')(4,2);", .expected = 42 },
    .{ .name = "function-constructor-parameter-fragments", .source = "var R;R=Function('a,b','c','return a*100+b*10+c')(4,2,1);", .expected = 421 },
    .{ .name = "function-constructor-zero-arguments", .source = "var R;var f=Function();R=(typeof f==='function'?10:0)+(f()===undefined?1:0);", .expected = 11 },
    .{ .name = "function-constructor-body-string-coercion", .source = "var R;var f=Function({toString:function(){return 'return 37';}});R=f();", .expected = 37 },
    // Property ownership and enumerability must agree across reflection and
    // iteration, including functions, sparse arrays and coerced property keys.
    .{ .name = "own-property-enumerable-flags", .source = "var R;var o={yes:1};Object.defineProperty(o,'hidden',{value:2,enumerable:false});R=(o.hasOwnProperty('hidden')?100:0)+(o.propertyIsEnumerable('hidden')?10:0)+(o.propertyIsEnumerable('yes')?1:0);", .expected = 101 },
    .{ .name = "function-own-property-reflection", .source = "var R;function f(){}f.x=1;R=(f.hasOwnProperty('x')?10:0)+(f.propertyIsEnumerable('x')?1:0);", .expected = 11 },
    .{ .name = "function-metadata-own-nonenumerable", .source = "var R;function f(a){}R=(f.hasOwnProperty('length')?100:0)+(f.hasOwnProperty('name')?10:0)+(f.propertyIsEnumerable('length')?1:0);", .expected = 110 },
    .{ .name = "array-own-index-and-length", .source = "var R;var a=[undefined];R=(a.hasOwnProperty('0')?100:0)+(a.hasOwnProperty(0)?10:0)+(a.hasOwnProperty('length')?1:0);", .expected = 111 },
    .{ .name = "array-length-is-nonenumerable", .source = "var R;var a=[1];R=(a.propertyIsEnumerable('0')?100:0)+(a.propertyIsEnumerable('length')?10:0)+(a.hasOwnProperty('length')?1:0);", .expected = 101 },
    .{ .name = "array-hole-distinct-from-undefined", .source = "var R;var a=Array(3);a[1]=undefined;R=(a.hasOwnProperty('0')?100:0)+(a.hasOwnProperty('1')?10:0)+(a.hasOwnProperty('2')?1:0);", .expected = 10 },
    .{ .name = "for-in-array-own-and-inherited-keys", .source = "var R;Array.prototype.inherited=3;var a=Array(3);a[1]=2;a.own=5;var keys='';for(var k in a)keys+=k+',';R=(keys==='1,own,inherited,'?1:0);", .expected = 1 },
    .{ .name = "for-in-function-own-properties", .source = "var R;function f(){}f.x=2;var n=0;for(var k in f)n++;R=n;", .expected = 1 },
    .{ .name = "object-keys-excludes-hidden", .source = "var R;var o={yes:1};Object.defineProperty(o,'hidden',{value:2,enumerable:false});R=(Object.keys(o).join(',')==='yes'?1:0);", .expected = 1 },
    .{ .name = "object-keys-function-properties", .source = "var R;function f(){}f.x=1;R=(Object.keys(f).join(',')==='x'?1:0);", .expected = 1 },
    .{ .name = "own-property-negative-fractional-key", .source = "var R;var o={'-1':1,'1.5':2};R=(o.hasOwnProperty(-1)?10:0)+(o.hasOwnProperty(1.5)?1:0);", .expected = 11 },
    .{ .name = "own-property-object-key-coercion", .source = "var R;var o={chosen:1};var key={toString:function(){return 'chosen';}};R=o.hasOwnProperty(key)?1:0;", .expected = 1 },
    .{ .name = "array-literal-elision-is-a-hole", .source = "var R;var a=[,undefined,,];R=a.length*100+(a.hasOwnProperty('0')?10:0)+(a.hasOwnProperty('1')?1:0);", .expected = 301 },
    .{ .name = "array-delete-string-index-creates-hole", .source = "var R;var a=[1,2,3];delete a['1'];R=a.length*100+(a.hasOwnProperty('1')?10:0)+(Object.keys(a).join(',')==='0,2'?1:0);", .expected = 301 },
    .{ .name = "array-hole-inherits-index-value", .source = "var R;Array.prototype[0]=7;var a=Array(1);R=a[0]*10+a['0'];", .expected = 77 },
    .{ .name = "object-keys-numeric-and-creation-order", .source = "var R;var o={};o.b=1;o[10]=1;o[2]=1;o['01']=1;o.a=1;R=(Object.keys(o).join(',')==='2,10,b,01,a'?1:0);", .expected = 1 },
    .{ .name = "function-prototype-property-stays-hidden", .source = "var R;function f(){}var p=f.prototype;R=(f.hasOwnProperty('prototype')?100:0)+(f.propertyIsEnumerable('prototype')?10:0)+Object.keys(f).length;", .expected = 100 },
    .{ .name = "string-64kb-length-and-last-byte", .source = "var R;var s='a';for(var i=0;i<16;i++)s=s+s;R=s.length*10+(s.charAt(65535)==='a'?1:0);", .expected = 655361 },
    .{ .name = "string-arena-retains-distinct-large-strings", .source = "var R;var s='a';for(var i=0;i<16;i++)s=s+s;var a=[];for(var j=0;j<64;j++)a.push(s+j);R=a[63].length*10+(a[63].slice(-2)==='63'?1:0);", .expected = 655381 },
    .{ .name = "long-function-source-concat-eval-roundtrip", .source = "var R;var s='a';for(var i=0;i<16;i++)s=s+s;var src='function f(){/*'+s+'*/return 7;}';eval(src);R=(f.toString()===src?100:0)+f();", .expected = 107 },
    .{ .name = "string-concat-method-retains-long-source", .source = "var R;var s='a';for(var i=0;i<16;i++)s=s+s;var t=s.concat('END');R=t.length*10+(t.slice(-3)==='END'?1:0);", .expected = 655391 },
    .{ .name = "string-concat-coerces-arguments", .source = "var R;R=('x'.concat(2.5,true,null,undefined)==='x2.5truenullundefined'?1:0);", .expected = 1 },
    .{ .name = "string-concat-reentrant-coercion", .source = "var R;var o={toString:function(){return 'A'.concat('B');}};R=('P'.concat(o,'Q')==='PABQ'?1:0);", .expected = 1 },
    .{ .name = "for-in-array-over-4096-elements", .source = "var R;var a=[];for(var i=0;i<5000;i++)a.push(i);Array.prototype[4500]=9;var n=0;for(var k in a)n++;R=n;", .expected = 5000 },
};

pub const case_count: usize = cases.len + 2;

pub fn runAll(comptime report: fn ([]const u8, f64, f64) void) u32 {
    var failed: u32 = 0;
    for (cases) |case| {
        const result = jsvm.dbgEvalGlobalNumber(case.source, "R");
        report(case.name, result, case.expected);
        if (result != case.expected) failed += 1;
    }
    // Check persisted frame metadata as well as expression results: reserving
    // stale locals can remain invisible until an actual BotGuard frame stack
    // overlaps, and a receiver name read from source offset zero can masquerade
    // as an unrelated binding in a later eval.
    _ = jsvm.dbgEvalGlobalNumber("var R;function f(){eval('var a=1;var b=2;');R=eval('7');}f();", "R");
    const eval_id = compiler.lastEvalBodyFunc();
    const local_count: f64 = if (eval_id != 0xFFFF) @floatFromInt(compiler.getFunction(eval_id).local_count) else -1;
    report("eval-frame-local-reservation-resets", local_count, 1);
    if (local_count != 1) failed += 1;
    _ = jsvm.dbgEvalGlobalNumber("var R;function f(){return 1;}R=f();", "R");
    const receiver_name = compiler.funcLocalName(0, 0);
    const receiver_ok: f64 = if (receiver_name == values.internString("this")) 1 else 0;
    report("internal-receiver-name-is-persistent", receiver_ok, 1);
    if (receiver_ok != 1) failed += 1;
    return failed;
}
