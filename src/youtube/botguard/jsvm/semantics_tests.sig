// Fixed-storage regressions for JavaScript semantics used by BotGuard.
// The caller supplies reporting; this shared suite has no platform dependency.
const jsvm = @import("root.sig");
const compiler = @import("compiler.sig");
const values = @import("values.sig");

const Case = struct { name: []const u8, source: []const u8, expected: f64 };
const cases = [_]Case{
    .{ .name = "object-freeze-preserves-target-and-properties", .source = "var o={x:1};var same=Object.freeze(o);o.x=2;o.y=3;delete o.x;var R=(same===o?1:0)+(o.x===1?2:0)+(o.y===undefined?4:0)+(Object.isFrozen(o)?8:0);", .expected = 15 },
    .{ .name = "borrowed-object-freeze-and-frozen-array-assignment", .source = "var f=Object.freeze;var a=[1,2];var same=f(a);a[0]=3;var R=(same===a?1:0)+(a[0]===1?2:0);", .expected = 3 },
    .{ .name = "sliced-register-bank-retains-old-closure-cell", .source = "function cell(v){var c={};c.create=function(){return v;};c.concat=function(x){v=x;};return c;}function put(a,i,v){if(a[i])a[i].concat(v);else a[i]=cell(v);}var a=[];put(a,94,10);var saved=a.slice();a[94]=void 0;put(a,94,20);put(a,94,21);var R=saved[94].create()*100+a[94].create();", .expected = 1021 },
    .{ .name = "sliced-register-bank-shares-existing-closure-cell", .source = "function cell(v){return {create:function(){return v;},concat:function(x){v=x;}};}var a=[];a[94]=cell(10);var saved=a.slice();a[94].concat(20);var R=saved[94].create();", .expected = 20 },
    .{ .name = "chrome-timing-methods-return-independent-objects", .source = "var a=chrome.loadTimes(),b=chrome.csi();var R=(typeof chrome.app==='object'?1:0)+(typeof a==='object'&&typeof b==='object'&&a!==b&&a!==chrome?2:0);", .expected = 3 },
    .{ .name = "navigator-attributes-are-inherited", .source = "var R=(Object.getOwnPropertyDescriptor(navigator,'webdriver')===undefined?1:0)+(navigator.webdriver===false?2:0)+(Object.getPrototypeOf(navigator)===Navigator.prototype?4:0);", .expected = 7 },
    .{ .name = "dom-prototype-reflection-retains-geometry-and-orientation-fields", .source = "var R=(Object.getOwnPropertyNames(SVGRect.prototype).join(',')==='constructor,x,y,width,height'?1:0)+(Object.getOwnPropertyNames(DeviceOrientationEvent.prototype).join(',')==='constructor,alpha,beta,gamma,absolute'?2:0);", .expected = 3 },
    .{ .name = "atan2-quadrants-and-infinities", .source = "var R=(Math.abs(Math.atan2(1,1)-Math.PI/4)<1e-15?1:0)+(Math.abs(Math.atan2(1,-1)-3*Math.PI/4)<1e-15?2:0)+(Math.atan2(1/0,1/0)===Math.PI/4?4:0)+(Math.atan2(-1,0)===-Math.PI/2?8:0);", .expected = 15 },
    .{ .name = "atan2-signed-zero-and-nan", .source = "var n=Math.atan2(0/0,1);var R=(1/Math.atan2(-0,1)<0?1:0)+(Math.atan2(0,-0)===Math.PI?2:0)+(Math.atan2(-0,-0)===-Math.PI?4:0)+(n!==n?8:0);", .expected = 15 },
    .{ .name = "string-converts-functions-arrays-and-custom-objects", .source = "var R=(String([1,2])==='1,2'?1:0)+(String({toString:function(){return 'ok';}})==='ok'?2:0)+(String(function f(){return 7;}).indexOf('function f')===0?4:0);", .expected = 7 },
    .{ .name = "string-conversion-falls-back-to-valueOf", .source = "var R=String({toString:function(){return {};},valueOf:function(){return 9;}})==='9'?1:0;", .expected = 1 },
    .{ .name = "function-toString-invalid-receiver-throws", .source = "var R=0;try{Function.prototype.toString.call({});}catch(e){R=e.name==='TypeError'?1:0;}", .expected = 1 },
    .{ .name = "array-invalid-length-throws-range-error", .source = "var R=0;[-1,1.5,0/0,1/0,4294967296].forEach(function(n){try{Array(n);}catch(e){if(e.name==='RangeError')R++;}});", .expected = 5 },
    .{ .name = "number-invalid-radix-throws-range-error", .source = "var R=0;[0,1,37,0/0,1/0].forEach(function(n){try{(7).toString(n);}catch(e){if(e.name==='RangeError')R++;}});", .expected = 5 },
    .{ .name = "loose-equality-array-primitive", .source = "var R;R=([]==false&&[1]==true&&['']==0&&[2]==2&&[2]!=[2])?1:0;", .expected = 1 },
    .{ .name = "array-arithmetic-and-default-addition", .source = "var R;R=(+[]===0&&+[3]===3&&[]+5==='5'&&[1,2]+3==='1,23')?1:0;", .expected = 1 },
    .{ .name = "object-valueof-before-tostring", .source = "var R;var order='';var x={valueOf:function(){order+='v';return 3},toString:function(){order+='s';return '9'}};R=(x+2===5&&x==3&&order==='vv')?1:0;", .expected = 1 },
    .{ .name = "sort-honors-descending-comparator", .source = "var R;var a=[2,10,1];a.sort(function(a,b){return b-a});R=a[0]*100+a[1]*10+a[2];", .expected = 1021 },
    .{ .name = "own-names-include-hidden-array-length", .source = "var R;var a=[7];Object.defineProperty(a,'hidden',{value:2});var n=Object.getOwnPropertyNames(a);R=(n.indexOf('0')>=0&&n.indexOf('length')>=0&&n.indexOf('hidden')>=0&&Object.keys(a).indexOf('hidden')<0)?1:0;", .expected = 1 },
    .{ .name = "btoa-does-not-truncate-at-4096", .source = "var R;var s='x'.repeat(4000);R=atob(btoa(s)).length;", .expected = 4000 },
    .{ .name = "detached-dom-focus-method", .source = "var R;var img=document.createElement('img');R=(typeof img.focus==='function'&&typeof img.blur==='function'&&img.focus()===undefined&&img.blur()===undefined)?1:0;", .expected = 1 },
    .{ .name = "detached-dom-scroll-extents", .source = "var R;var img=document.createElement('img');R=(typeof img.scrollWidth==='number'&&typeof img.scrollHeight==='number'&&img.scrollWidth===0&&img.scrollHeight===0)?1:0;", .expected = 1 },
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
    // BotGuard reads its local operand FIFO inside a labeled block. A named
    // break must skip the byte-reader fallback after its inner while loop.
    .{ .name = "labeled-break-skips-fifo-fallback", .source = "var R=0;a:{while(true){R=93;break a;if(5)break;}R=95;}", .expected = 93 },
    .{ .name = "labeled-break-outer-block-from-nested-loops", .source = "var R=0;out:{for(var i=0;i<3;i++){for(var j=0;j<3;j++){R++;break out;}R+=10;}R+=100;}R+=1000;", .expected = 1001 },
    .{ .name = "labeled-and-bare-breaks-stay-distinct", .source = "var R=0;out:{for(var i=0;i<3;i++){for(var j=0;j<3;j++){R++;break;}if(i===1)break out;R+=10;}R+=100;}", .expected = 12 },
    .{ .name = "labeled-continue-outer-for-update", .source = "var R=0;out:for(var i=0;i<3;i++){for(var j=0;j<2;j++){R++;continue out;}R+=100;}", .expected = 3 },
    .{ .name = "labeled-continue-outer-while-condition", .source = "var R=0,i=0;out:while(i<3){i++;while(true){R+=i;continue out;}R=999;}", .expected = 6 },
    .{ .name = "labeled-continue-do-while-condition", .source = "var R=0,i=0;out:do{i++;while(true){R++;continue out;}R+=100;}while(i<3);", .expected = 3 },
    .{ .name = "chained-labels-share-for-continue-target", .source = "var R=0;first:second:for(var i=0;i<3;i++){for(var j=0;j<2;j++){R++;continue first;}R+=100;}", .expected = 3 },
    .{ .name = "labeled-continue-outer-for-in", .source = "var R=0;out:for(var k in {a:1,b:2,c:3}){while(true){R++;continue out;}R+=100;}", .expected = 3 },
    .{ .name = "function-definition-preserves-enclosing-break-patch", .source = "var R=0;out:{while(true){R=7;break out;function f(){while(true){break;}}}R=99;}", .expected = 7 },
    .{ .name = "function-definition-preserves-enclosing-continue-patch", .source = "var R=0;out:for(var i=0;i<3;i++){R++;continue out;function f(){while(true){continue;}}R+=100;}", .expected = 3 },
    .{ .name = "labeled-continue-closes-inner-for-in", .source = "var R=0;out:for(var k in {a:1,b:2,c:3}){for(var j in {x:1,y:2}){R++;continue out;}R+=100;}", .expected = 3 },
    .{ .name = "bare-break-closes-for-in-before-next-loop", .source = "var R=0;for(var i=0;i<100;i++){for(var k in {a:1}){R++;break;}}", .expected = 100 },
    .{ .name = "labeled-break-closes-nested-for-in", .source = "var R=0;for(var i=0;i<100;i++){out:for(var k in {a:1}){for(var j in {b:2}){R++;break out;}}}", .expected = 100 },
    .{ .name = "labeled-break-switch-discards-discriminant", .source = "var R=0;for(var i=0;i<20000;i++){out:{switch(1){case 1:R++;break out;}R+=100;}}", .expected = 20000 },
    .{ .name = "bare-break-switch-discards-discriminant", .source = "var R=0;for(var i=0;i<20000;i++){switch(1){case 1:R++;break;}}", .expected = 20000 },
    .{ .name = "labeled-continue-switch-discards-discriminant", .source = "var R=0;out:for(var i=0;i<20000;i++){switch(1){case 1:R++;continue out;}R+=100;}", .expected = 20000 },
    .{ .name = "arguments-zero-formals-preserves-extra-actuals", .source = "var R;function f(){return arguments.length*100+arguments[0]*10+arguments[2];}R=f(4,8,2);", .expected = 342 },
    .{ .name = "arguments-empty-and-missing-actuals", .source = "var R;function f(a,b){return arguments.length*100+(arguments.hasOwnProperty('0')?10:0)+(b===undefined?1:0);}R=f()+f(7);", .expected = 112 },
    .{ .name = "arguments-callee-and-object-brand", .source = "var R;function f(){return (arguments.callee===f?100:0)+(Array.isArray(arguments)?0:10)+(Object.prototype.toString.call(arguments)==='[object Arguments]'?1:0);}R=f();", .expected = 111 },
    .{ .name = "arguments-extra-values-do-not-seed-locals", .source = "var R;function f(a){var b;return (b===undefined?100:0)+arguments[1];}R=f(3,7);", .expected = 107 },
    .{ .name = "arguments-method-call-and-apply", .source = "var R;var o={x:5,f:function(){return this.x*100+arguments.length*10+arguments[1];}};R=o.f(1,3)+o.f.call({x:2},4,6)+o.f.apply({x:1},[7,8]);", .expected = 877 },
    .{ .name = "arguments-object-forwards-through-apply", .source = "var R;function g(a,b,c){return arguments.length*100+a*10+c;}function f(){return g.apply(null,arguments);}R=f(4,8,2);", .expected = 342 },
    .{ .name = "apply-plain-array-like-object", .source = "var R;function f(a,b){return arguments.length*100+a*10+b;}R=f.apply(null,{length:2,0:4,1:2});", .expected = 242 },
    .{ .name = "for-var-multiple-declarators", .source = "var R=0;for(var i=0,j=3;i<j;i++)R+=j;", .expected = 9 },
    .{ .name = "switch-middle-default-keeps-later-match", .source = "var R=0;switch(3){case 1:R=10;break;default:R=20;break;case 3:R=30;break;}", .expected = 30 },
    .{ .name = "switch-middle-default-falls-through-later-body", .source = "var R=0;switch(9){case 1:R=10;break;default:R=20;case 3:R+=3;}", .expected = 23 },
    .{ .name = "switch-tests-later-case-before-default", .source = "var R=0;function c(n){R=R*10+n;return n;}switch(8){case c(1):R+=1000;break;default:R+=100;break;case c(2):R+=2000;break;}", .expected = 112 },
    .{ .name = "switch-match-before-default-skips-later-test", .source = "var R=0;function c(n){R=R*10+n;return n;}switch(1){case c(1):R+=100;break;default:R+=1000;break;case c(2):R+=2000;break;}", .expected = 101 },
    .{ .name = "array-search-tagged-string-and-object-identity", .source = "var o={};var a=['x','y',o,{}];var R=a.indexOf('y')*100+(a.includes('x')?10:0)+(a.indexOf(o)===2&&a.indexOf({})===-1?1:0);", .expected = 111 },
    .{ .name = "array-search-nan-holes-and-negative-zero", .source = "var a=[,0/0,-0];var R=(a.indexOf(undefined)===-1?1:0)+(a.includes(undefined)?2:0)+(a.indexOf(0/0)===-1?4:0)+(a.includes(0/0)?8:0)+(a.indexOf(0)===2?16:0);", .expected = 31 },
    .{ .name = "array-search-relative-from-index", .source = "var a=['x','y','x'];var R=a.indexOf('x',1)*100+(a.indexOf('x',-1)===2?10:0)+(a.includes('y',-1)?0:1)+(a.indexOf('x',1/0)===-1?1000:0)+(a.indexOf('x',-1/0)===0?10000:0);", .expected = 11211 },
    .{ .name = "array-character-search-with-growing-short-callback-key", .source = "var C='0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_'.split('');var a='1UAnrqce4NVxc42TVy'.split(''),e=C.length;a.forEach(function(T,U,E){this.push(E[U]=C[(C.indexOf(T)-C.indexOf(this[U])+U+e--)%C.length]);},'debugger'.split(''));var R=a.join('')==='QGpVba-Pg7wE1W44Fr'?1:0;", .expected = 1 },
    .{ .name = "for-let-multiple-declarators-prefix-condition", .source = "var R=0;for(let i=0,j=2;++i<j+2;)R+=i+j;", .expected = 12 },
    .{ .name = "date-iso-positive-timezone-offset", .source = "var R=+new Date('1970-01-01T02:30:41.000+02:30');", .expected = 41000 },
    .{ .name = "date-iso-negative-timezone-offset", .source = "var R=+new Date('1969-12-31T16:45:46.000-07:15');", .expected = 46000 },
    .{ .name = "date-iso-negative-offset-crosses-epoch", .source = "var R=+new Date('1969-12-31T17:15:05.000-06:45');", .expected = 5000 },
    .{ .name = "date-numeric-value-methods-and-brand", .source = "var d=new Date(7);var R=d.getTime()+d.valueOf()+(Object.prototype.toString.call(d)==='[object Date]'?100:0);", .expected = 114 },
    .{ .name = "remainder-negative-dividend", .source = "var R=-7%3;", .expected = -1 },
    .{ .name = "remainder-negative-divisor", .source = "var R=7%-3;", .expected = 1 },
    .{ .name = "remainder-zero-nan-and-infinite-dividend", .source = "var a=7%0,b=7%(0/0),c=(1/0)%3;var R=(a!==a?1:0)+(b!==b?2:0)+(c!==c?4:0);", .expected = 7 },
    .{ .name = "remainder-infinite-divisor-retains-dividend", .source = "var R=7%(1/0)-(-7%(-1/0));", .expected = 14 },
    .{ .name = "remainder-negative-zero-retains-sign", .source = "var R=(1/(-6%3)<0?10:0)+(1/(-0%3)<0?1:0);", .expected = 11 },
    .{ .name = "arguments-nested-function-has-own-object", .source = "var R;function f(){function g(){return arguments[0]+arguments.length;}return arguments[0]*10+g(7,8);}R=f(3);", .expected = 39 },
    .{ .name = "arguments-arrow-inherits-enclosing-object", .source = "var R;function f(){return (()=>arguments[1]+arguments.length)();}R=f(4,7,9);", .expected = 10 },
    .{ .name = "arguments-escaped-arrow-captures-enclosing-object", .source = "var R;function f(){return ()=>arguments[0]+arguments.length;}var g=f(7,8);R=g(99);", .expected = 9 },
    .{ .name = "arguments-direct-eval-inherits-object", .source = "var R;function f(){return eval('arguments[0]+arguments.length');}R=f(7,8);", .expected = 9 },
    .{ .name = "arguments-nested-direct-eval-in-arrow", .source = "var R;function f(){return (()=>eval('eval(\"arguments[1]+arguments.length\")'))();}R=f(1,7);", .expected = 9 },
    .{ .name = "arguments-formal-name-shadows-implicit-binding", .source = "var R;function f(arguments){return arguments+1;}R=f(7);", .expected = 8 },
    .{ .name = "arguments-var-initializer-replaces-binding", .source = "var R;function f(){var arguments=13;return arguments;}R=f(7);", .expected = 13 },
    .{ .name = "arguments-local-block-shadows-implicit-binding", .source = "var R;function f(){var n=arguments[0];{let arguments=9;n+=arguments;}return n+arguments.length;}R=f(7,8);", .expected = 18 },
    .{ .name = "arguments-sloppy-parameter-alias-both-directions", .source = "var R;function f(a){a=7;var n=arguments[0];arguments[0]=8;return n*10+a;}R=f(1);", .expected = 78 },
    .{ .name = "arguments-unsupplied-formal-remains-unmapped", .source = "var R;function f(a,b){arguments[1]=8;return (b===undefined?10:0)+arguments[1];}R=f(1);", .expected = 18 },
    .{ .name = "arguments-duplicate-parameter-maps-last-index", .source = "var R;function f(a,a){a=7;arguments[0]=8;return arguments[0]*100+arguments[1]*10+a;}R=f(1,2);", .expected = 877 },
    .{ .name = "arguments-strict-parameters-are-unmapped", .source = "var R;function f(a){'use strict';a=7;var n=arguments[0];arguments[0]=8;return n*10+a;}R=f(1);", .expected = 17 },
    .{ .name = "arguments-escaped-object-shares-closed-parameter", .source = "var R;function f(a){return [arguments,function(){return a;}];}var p=f(1);p[0][0]=7;R=p[1]();", .expected = 7 },
    .{ .name = "arguments-exception-unwind-closes-mapped-parameter", .source = "var R;var p;function f(a){p=[arguments,function(){return a;}];throw 2;}try{f(1);}catch(e){}p[0][0]=7;R=p[1]();", .expected = 7 },
    .{ .name = "arguments-delete-detaches-parameter-map", .source = "var R;function f(a){delete arguments[0];arguments[0]=8;return a*10+arguments[0];}R=f(1);", .expected = 18 },
    .{ .name = "arguments-getter-detaches-parameter-map", .source = "var R;function f(a){Object.defineProperty(arguments,'0',{get:function(){return 9;}});a=7;return a*10+arguments[0];}R=f(1);", .expected = 79 },
    .{ .name = "arguments-readonly-detaches-at-current-value", .source = "var R;function f(a){a=7;Object.defineProperty(arguments,'0',{writable:false});a=9;arguments[0]=8;return a*10+arguments[0];}R=f(1);", .expected = 97 },
    .{ .name = "arguments-descriptor-reflects-live-parameter", .source = "var R;function f(a){a=7;var d=Object.getOwnPropertyDescriptor(arguments,'0');var l=Object.getOwnPropertyDescriptor(arguments,'length');return d.value*100+(d.writable?10:0)+(d.enumerable?1:0)+(l.enumerable?1000:0);}R=f(1);", .expected = 711 },
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
