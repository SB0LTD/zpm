//! Sig-owned resident GGML matrix-vector kernel. No CUDA-C compiler or
//! external kernel source is used. Each warp reduces one output row by
//! default, with an optional whole-block reduction for numerical comparisons.
//! Each lane dequantizes its exact Q4_K/Q6_K coefficient from packed VRAM.
pub const source: [:0]const u8 =
    \\.version 7.0
    \\.target sm_50
    \\.address_size 64
    \\.visible .entry text_packed_matvec(
    \\ .param .u64 weights,.param .u64 input,.param .u64 output,
    \\ .param .u32 columns,.param .u32 rows,.param .u32 row_bytes,.param .u32 type,.param .u32 warp_rows) {
    \\ .reg .pred %p<5>; .reg .b16 %h<2>; .reg .b32 %r<40>; .reg .b64 %d<20>; .reg .f32 %f<12>;
    \\ .shared .align 4 .b8 sums[1024];
    \\ ld.param.u64 %d0,[weights]; ld.param.u64 %d1,[input]; ld.param.u64 %d2,[output];
    \\ ld.param.u32 %r0,[columns]; ld.param.u32 %r1,[rows]; ld.param.u32 %r2,[row_bytes]; ld.param.u32 %r3,[type];
    \\ ld.param.u32 %r23,[warp_rows]; mov.u32 %r22,256;
    \\ mov.u32 %r4,%ctaid.x; mov.u32 %r5,%tid.x; setp.eq.u32 %p0,%r23,0; @%p0 bra ROW_READY;
    \\ shr.u32 %r24,%r5,5; mad.lo.u32 %r4,%r4,8,%r24; and.b32 %r5,%r5,31; mov.u32 %r22,32;
    \\ ROW_READY: setp.ge.u32 %p0,%r4,%r1; @%p0 bra DONE;
    \\ mul.wide.u32 %d3,%r4,%r2; add.u64 %d4,%d0,%d3; mov.u32 %r6,%r5; mov.f32 %f0,0f00000000;
    \\ COEFFICIENT: setp.ge.u32 %p0,%r6,%r0; @%p0 bra REDUCE;
    \\ and.b32 %r21,%r6,255;
    \\ mul.wide.u32 %d5,%r6,4; add.u64 %d6,%d1,%d5; ld.global.f32 %f1,[%d6];
    \\ setp.eq.u32 %p0,%r3,0; @%p0 bra FLOAT_WEIGHT;
    \\ shr.u32 %r7,%r6,8; setp.eq.u32 %p0,%r3,14; @%p0 bra Q6_WEIGHT;
    \\ // Q4_K: d,dmin, twelve packed 6-bit scale/min fields, 128 nibbles.
    \\ mul.wide.u32 %d7,%r7,144; add.u64 %d8,%d4,%d7;
    \\ ld.global.b16 %h0,[%d8]; ld.global.b16 %h1,[%d8+2]; cvt.f32.f16 %f2,%h0; cvt.f32.f16 %f3,%h1;
    \\ shr.u32 %r8,%r21,5; and.b32 %r9,%r21,31; shr.u32 %r10,%r21,6;
    \\ and.b32 %r11,%r8,1; shl.b32 %r11,%r11,2; mad.lo.u32 %r12,%r10,32,%r9; add.u32 %r12,%r12,16;
    \\ cvt.u64.u32 %d9,%r12; add.u64 %d10,%d8,%d9; ld.global.u8 %r13,[%d10]; shr.u32 %r13,%r13,%r11; and.b32 %r13,%r13,15;
    \\ add.u64 %d9,%d8,4; setp.ge.u32 %p0,%r8,4; @%p0 bra Q4_HIGH_SCALE;
    \\ cvt.u64.u32 %d10,%r8; add.u64 %d10,%d9,%d10; ld.global.u8 %r14,[%d10]; ld.global.u8 %r15,[%d10+4];
    \\ and.b32 %r14,%r14,63; and.b32 %r15,%r15,63; bra Q4_COMPUTE;
    \\ Q4_HIGH_SCALE: add.u32 %r16,%r8,4; cvt.u64.u32 %d10,%r16; add.u64 %d10,%d9,%d10; ld.global.u8 %r16,[%d10];
    \\ sub.u32 %r17,%r8,4; cvt.u64.u32 %d10,%r17; add.u64 %d10,%d9,%d10; ld.global.u8 %r17,[%d10];
    \\ cvt.u64.u32 %d10,%r8; add.u64 %d10,%d9,%d10; ld.global.u8 %r18,[%d10];
    \\ and.b32 %r14,%r16,15; shr.u32 %r17,%r17,6; shl.b32 %r17,%r17,4; or.b32 %r14,%r14,%r17;
    \\ shr.u32 %r15,%r16,4; shr.u32 %r18,%r18,6; shl.b32 %r18,%r18,4; or.b32 %r15,%r15,%r18;
    \\ Q4_COMPUTE: cvt.rn.f32.u32 %f4,%r14; cvt.rn.f32.u32 %f5,%r15; cvt.rn.f32.u32 %f6,%r13;
    \\ mul.f32 %f4,%f2,%f4; mul.f32 %f5,%f3,%f5; mul.f32 %f6,%f4,%f6; sub.f32 %f6,%f6,%f5; bra PRODUCT;
    \\ // Q6_K: 128 low-nibble bytes,64 high-two-bit bytes,16 signed scales,d.
    \\ Q6_WEIGHT: mul.wide.u32 %d7,%r7,210; add.u64 %d8,%d4,%d7;
    \\ shr.u32 %r8,%r21,7; and.b32 %r9,%r21,127; shr.u32 %r9,%r9,5; and.b32 %r10,%r21,31;
    \\ and.b32 %r11,%r9,1; shl.b32 %r11,%r11,5; mad.lo.u32 %r12,%r8,64,%r10; add.u32 %r12,%r12,%r11;
    \\ cvt.u64.u32 %d9,%r12; add.u64 %d10,%d8,%d9; ld.global.u8 %r13,[%d10];
    \\ shr.u32 %r11,%r9,1; shl.b32 %r11,%r11,2; shr.u32 %r13,%r13,%r11; and.b32 %r13,%r13,15;
    \\ mad.lo.u32 %r12,%r8,32,%r10; add.u32 %r12,%r12,128; cvt.u64.u32 %d9,%r12; add.u64 %d10,%d8,%d9; ld.global.u8 %r14,[%d10];
    \\ shl.b32 %r11,%r9,1; shr.u32 %r14,%r14,%r11; and.b32 %r14,%r14,3; shl.b32 %r14,%r14,4; or.b32 %r13,%r13,%r14; sub.s32 %r13,%r13,32;
    \\ shr.u32 %r11,%r10,4; mad.lo.u32 %r12,%r9,2,%r11; mad.lo.u32 %r12,%r8,8,%r12; add.u32 %r12,%r12,192;
    \\ cvt.u64.u32 %d9,%r12; add.u64 %d10,%d8,%d9; ld.global.s8 %r14,[%d10]; ld.global.b16 %h0,[%d8+208];
    \\ cvt.f32.f16 %f2,%h0; cvt.rn.f32.s32 %f4,%r14; cvt.rn.f32.s32 %f5,%r13; mul.f32 %f6,%f2,%f4; mul.f32 %f6,%f6,%f5; bra PRODUCT;
    \\ FLOAT_WEIGHT: add.u64 %d8,%d4,%d5; ld.global.f32 %f6,[%d8];
    \\ PRODUCT: mul.f32 %f7,%f6,%f1; add.f32 %f0,%f0,%f7; add.u32 %r6,%r6,%r22; bra COEFFICIENT;
    \\ REDUCE: setp.ne.u32 %p0,%r23,0; @%p0 bra WARP_REDUCE;
    \\ mov.u64 %d11,sums; mul.wide.u32 %d12,%r5,4; add.u64 %d13,%d11,%d12; st.shared.f32 [%d13],%f0; bar.sync 0; mov.u32 %r20,128;
    \\ REDUCE_STEP: setp.ge.u32 %p1,%r5,%r20; @%p1 bra REDUCE_WAIT;
    \\ mul.wide.u32 %d14,%r20,4; add.u64 %d15,%d13,%d14; ld.shared.f32 %f1,[%d15]; add.f32 %f0,%f0,%f1; st.shared.f32 [%d13],%f0;
    \\ REDUCE_WAIT: bar.sync 0; shr.u32 %r20,%r20,1; setp.ne.u32 %p1,%r20,0; @%p1 bra REDUCE_STEP;
    \\ bra STORE_RESULT;
    \\ WARP_REDUCE: mov.u32 %r20,16;
    \\ WARP_REDUCE_STEP: mov.b32 %r30,%f0; shfl.sync.bfly.b32 %r31,%r30,%r20,31,-1; mov.b32 %f1,%r31; add.f32 %f0,%f0,%f1;
    \\ shr.u32 %r20,%r20,1; setp.ne.u32 %p1,%r20,0; @%p1 bra WARP_REDUCE_STEP;
    \\ STORE_RESULT: setp.ne.u32 %p1,%r5,0; @%p1 bra DONE;
    \\ mul.wide.u32 %d16,%r4,4; add.u64 %d17,%d2,%d16; st.global.f32 [%d17],%f0;
    \\ DONE: ret;
    \\}
;
