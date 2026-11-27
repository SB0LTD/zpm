// Independent public-fixture verification. No participant private-key reads.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash,createPrivateKey,createPublicKey,sign,verify} from 'node:crypto';
const [directory,tag='current',values='12,12,12,12']=process.argv.slice(2);
assert(directory);assert(/^[a-z0-9-]{1,48}$/.test(tag));
const expected=values.split(',').map(Number);assert.equal(expected.length,4);for(const n of expected)assert(Number.isInteger(n)&&n>=0&&n<=64);
const root=resolve(directory),realm=Buffer.alloc(32,72),zero=Buffer.alloc(32);
const hash=b=>createHash('sha256').update(b).digest();
const keys=Array.from({length:4},(_,id)=>{
 const privateKey=createPrivateKey({format:'der',type:'pkcs8',key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),Buffer.alloc(32,id+151)])});
 const publicKey=createPublicKey(privateKey);return {privateKey,publicKey,bytes:publicKey.export({format:'der',type:'spki'}).subarray(-32)};
});
const u64=n=>{const b=Buffer.alloc(8);b.writeBigUInt64LE(BigInt(n));return b;};
const histories=keys.map(key=>{
 const events=[null],heads=[zero];
 for(let n=1;n<=64;n++){
  const msg=Buffer.alloc(128);msg.write('ZMH1');msg[4]=1;msg[5]=1;realm.copy(msg,8);key.bytes.copy(msg,40);msg.writeBigUInt64LE(BigInt(n),72);heads[n-1].copy(msg,80);msg.writeUInt16LE(8,112);msg.writeBigUInt64LE(1n,120);
  const bytes=Buffer.concat([msg,sign(null,msg,key.privateKey)]);events.push(bytes);heads.push(hash(bytes));
 }return {events,heads};
});
function frame(bytes,writer){
 assert(bytes.length>=184&&bytes.length<=408);assert.equal(bytes.subarray(0,5).toString('hex'),'5a4d483101');
 assert(bytes.subarray(6,8).equals(Buffer.alloc(2)));assert(bytes.subarray(114,120).equals(Buffer.alloc(6)));assert(bytes.subarray(8,40).equals(realm));assert(bytes.subarray(40,72).equals(keys[writer].bytes));
 assert.equal(bytes.length,184+bytes.readUInt16LE(112));assert(verify(null,bytes.subarray(0,-64),keys[writer].publicKey,bytes.subarray(-64)));
 const sequence=Number(bytes.readBigUInt64LE(72));assert(sequence>=0&&sequence<=64);const kind=bytes[5];
 if(kind===1){assert(sequence>0);assert(bytes.equals(histories[writer].events[sequence]));}
 else {assert.equal(kind,2);assert.equal(bytes.length,192);assert(bytes.subarray(80,112).equals(histories[writer].heads[sequence]));assert.equal(bytes.readBigUInt64LE(120),BigInt(sequence));}
 return {sequence,kind};
}
const journals=[];
for(let node=0;node<4;node++){
 const bytes=readFileSync(resolve(root,`node-${node}/node-history.bin`));assert(bytes.length>=120);assert(bytes.subarray(-32).equals(hash(bytes.subarray(0,-32))),'Journal checksum');
 assert.equal(bytes.subarray(0,8).toString('hex'),'5a4d443101000000');assert(bytes.subarray(8,40).equals(realm));assert(bytes.subarray(40,72).equals(keys[node].bytes));assert.equal(bytes.readUInt16LE(80),4);assert(bytes.subarray(82,88).equals(Buffer.alloc(6)));
 const generation=bytes.readBigUInt64LE(72);assert(generation>0n);let pos=88;const streams=[];
 for(let writer=0;writer<4;writer++){
  assert(bytes.subarray(pos,pos+32).equals(keys[writer].bytes));const cursor=Number(bytes.readBigUInt64LE(pos+32)),head=bytes.subarray(pos+40,pos+72);assert.equal(cursor,expected[writer],`node=${node} writer=${writer} cursor`);assert(head.equals(histories[writer].heads[cursor]));
  const anchorSize=bytes.readUInt16LE(pos+72),count=bytes.readUInt16LE(pos+74);assert(count<=4);pos+=76;
  let state=0,anchor=0;
  if(anchorSize){const checkpoint=frame(bytes.subarray(pos,pos+anchorSize),writer);assert.equal(checkpoint.kind,2);anchor=checkpoint.sequence;state=anchor;assert(anchor<=cursor);pos+=anchorSize;}
  let last=0;
  for(let i=0;i<count;i++){
   const length=bytes.readUInt16LE(pos);pos+=2;const event=frame(bytes.subarray(pos,pos+length),writer);pos+=length;assert.equal(event.kind,1);if(last)assert.equal(event.sequence,last+1);last=event.sequence;
   if(event.sequence>anchor){assert.equal(event.sequence,state+1);state++;}
  }
  assert.equal(state,cursor);if(count)assert.equal(last,cursor);
  streams.push({writer,cursor,state,head:head.toString('hex'),anchor,retainedEvents:count});
 }
 assert.equal(pos,bytes.length-32);journals.push({node,generation:generation.toString(),bytes:bytes.length,streams});
}
const sorted=keys.map((key,writer)=>({key:key.bytes,writer})).sort((a,b)=>Buffer.compare(a.key,b.key));
const digest=createHash('sha256').update(realm);for(const {key,writer}of sorted)digest.update(key).update(u64(expected[writer])).update(histories[writer].heads[expected[writer]]).update(u64(expected[writer]));
const stateHash=digest.digest('hex');
const report={pass:true,tag,values:expected,stateHash,journals,checks:['atomic journal checksums and owner/realm binding','all retained events and snapshots verified independently with Ed25519','every stream head equals independently regenerated full event chain','state and persistent cursor equal exactly one effect per signed increment','all four replicas match the canonical state hash'],authority:'synthetic per-writer counter state; no Solana finality claim'};
writeFileSync(resolve(root,`${tag}-report.json`),JSON.stringify(report,null,2));console.log(JSON.stringify({pass:true,tag,values:expected,stateHash,generations:journals.map(j=>j.generation)},null,2));
