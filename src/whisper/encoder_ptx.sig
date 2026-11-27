//! Sig-owned GPU assembly for Whisper. No CUDA-C compiler or external kernel
//! implementation is used in production. Parameters are checked by callers.
pub const source =
    \\.visible .entry whisper_encoder_columns(.param .u64 src,.param .u64 dst,.param .u32 frames,.param .u32 channels,.param .u32 out_frames,.param .u32 stride,.param .u32 channel_major) {
    \\ .reg .pred %p<4>; .reg .b16 %h; .reg .b32 %r<20>; .reg .b64 %d<8>; .reg .f32 %f;
    \\ ld.param.u64 %d0,[src]; ld.param.u64 %d1,[dst];
    \\ ld.param.u32 %r0,[frames]; ld.param.u32 %r1,[channels]; ld.param.u32 %r2,[out_frames]; ld.param.u32 %r3,[stride]; ld.param.u32 %r4,[channel_major];
    \\ mov.u32 %r5,%ctaid.x; mov.u32 %r6,%ntid.x; mov.u32 %r7,%tid.x; mad.lo.u32 %r8,%r5,%r6,%r7;
    \\ mul.lo.u32 %r9,%r1,3; mul.lo.u32 %r10,%r9,%r2; setp.ge.u32 %p0,%r8,%r10; @%p0 bra COL_END;
    \\ div.u32 %r11,%r8,%r9; div.u32 %r12,%r8,3; rem.u32 %r12,%r12,%r1; rem.u32 %r13,%r8,3;
    \\ mad.lo.u32 %r14,%r11,%r3,%r13; mov.f32 %f,0f00000000;
    \\ setp.eq.u32 %p1,%r14,0; @%p1 bra COL_STORE; setp.gt.u32 %p1,%r14,%r0; @%p1 bra COL_STORE;
    \\ sub.u32 %r14,%r14,1; setp.ne.u32 %p2,%r4,0; @%p2 bra COL_CHANNEL;
    \\ mad.lo.u32 %r15,%r14,%r1,%r12; bra COL_LOAD;
    \\ COL_CHANNEL: mad.lo.u32 %r15,%r12,%r0,%r14;
    \\ COL_LOAD: mul.wide.u32 %d2,%r15,4; add.u64 %d3,%d0,%d2; ld.global.f32 %f,[%d3];
    \\ COL_STORE: cvt.rn.f16.f32 %h,%f; mul.wide.u32 %d4,%r8,2; add.u64 %d5,%d1,%d4; st.global.b16 [%d5],%h;
    \\ COL_END: ret;
    \\}
    \\.visible .entry whisper_encoder_expand(.param .u64 src,.param .u64 dst,.param .u32 count,.param .f32 scale) {
    \\ .reg .pred %p; .reg .b16 %h; .reg .b32 %r<5>; .reg .b64 %d<7>; .reg .f32 %f<2>;
    \\ ld.param.u64 %d0,[src]; ld.param.u64 %d1,[dst]; ld.param.u32 %r0,[count]; ld.param.f32 %f1,[scale];
    \\ mov.u32 %r1,%ctaid.x; mov.u32 %r2,%ntid.x; mov.u32 %r3,%tid.x; mad.lo.u32 %r4,%r1,%r2,%r3;
    \\ setp.ge.u32 %p,%r4,%r0; @%p bra EXPAND_END;
    \\ mul.wide.u32 %d2,%r4,2; add.u64 %d3,%d0,%d2; ld.global.u16 %h,[%d3]; cvt.f32.f16 %f0,%h; mul.f32 %f0,%f0,%f1;
    \\ mul.wide.u32 %d4,%r4,4; add.u64 %d5,%d1,%d4; st.global.f32 [%d5],%f0;
    \\ EXPAND_END: ret;
    \\}
    \\.visible .entry whisper_encoder_element(.param .u64 src,.param .u64 bias,.param .u64 dst,.param .u64 addend,.param .u32 count,.param .u32 width,.param .u32 flags) {
    \\ .reg .pred %p<6>; .reg .b16 %h; .reg .b32 %r<12>; .reg .b64 %d<15>; .reg .f32 %f<12>;
    \\ ld.param.u64 %d0,[src]; ld.param.u64 %d1,[bias]; ld.param.u64 %d2,[dst]; ld.param.u64 %d3,[addend];
    \\ ld.param.u32 %r0,[count]; ld.param.u32 %r1,[width]; ld.param.u32 %r2,[flags];
    \\ mov.u32 %r3,%ctaid.x; mov.u32 %r4,%ntid.x; mov.u32 %r5,%tid.x; mad.lo.u32 %r6,%r3,%r4,%r5;
    \\ setp.ge.u32 %p0,%r6,%r0; @%p0 bra EL_END;
    \\ and.b32 %r7,%r2,1; setp.eq.u32 %p1,%r7,0; @%p1 bra EL_FLOAT;
    \\ mul.wide.u32 %d4,%r6,2; add.u64 %d5,%d0,%d4; ld.global.u16 %h,[%d5]; cvt.f32.f16 %f0,%h; bra EL_BIAS;
    \\ EL_FLOAT: mul.wide.u32 %d4,%r6,4; add.u64 %d5,%d0,%d4; ld.global.f32 %f0,[%d5];
    \\ EL_BIAS: setp.eq.u64 %p2,%d1,0; @%p2 bra EL_GELU;
    \\ rem.u32 %r8,%r6,%r1; mul.wide.u32 %d6,%r8,4; add.u64 %d7,%d1,%d6; ld.global.f32 %f1,[%d7]; add.f32 %f0,%f0,%f1;
    \\ EL_GELU: and.b32 %r7,%r2,4; setp.eq.u32 %p3,%r7,0; @%p3 bra EL_ADD;
    \\ mul.f32 %f2,%f0,%f0; mul.f32 %f2,%f2,0f3D372713; add.f32 %f2,%f2,0f3F800000;
    \\ mul.f32 %f3,%f0,0f3F4C422A; mul.f32 %f2,%f2,%f3; mul.f32 %f2,%f2,0fC038AA3B;
    \\ ex2.approx.ftz.f32 %f2,%f2; add.f32 %f2,%f2,0f3F800000; div.rn.f32 %f0,%f0,%f2;
    \\ EL_ADD: setp.eq.u64 %p4,%d3,0; @%p4 bra EL_STORE;
    \\ mul.wide.u32 %d8,%r6,4; add.u64 %d9,%d3,%d8; ld.global.f32 %f4,[%d9]; add.f32 %f0,%f0,%f4;
    \\ EL_STORE: and.b32 %r7,%r2,2; setp.eq.u32 %p5,%r7,0; @%p5 bra EL_STORE_FLOAT;
    \\ cvt.rn.f16.f32 %h,%f0; mul.wide.u32 %d10,%r6,2; add.u64 %d11,%d2,%d10; st.global.b16 [%d11],%h; bra EL_END;
    \\ EL_STORE_FLOAT: mul.wide.u32 %d10,%r6,4; add.u64 %d11,%d2,%d10; st.global.f32 [%d11],%f0;
    \\ EL_END: ret;
    \\}
    \\.visible .entry whisper_encoder_norm(.param .u64 src,.param .u64 weight,.param .u64 bias,.param .u64 dst,.param .u32 width,.param .u32 half_output) {
    \\ .reg .pred %p<6>; .reg .b16 %h; .reg .b32 %r<14>; .reg .b64 %d<18>; .reg .f32 %f<14>;
    \\ .shared .align 4 .b8 values[1024];
    \\ ld.param.u64 %d0,[src]; ld.param.u64 %d1,[weight]; ld.param.u64 %d2,[bias]; ld.param.u64 %d3,[dst];
    \\ ld.param.u32 %r0,[width]; ld.param.u32 %r1,[half_output]; mov.u32 %r2,%ctaid.x; mov.u32 %r3,%tid.x;
    \\ mul.lo.u32 %r4,%r2,%r0; mul.wide.u32 %d4,%r4,4; add.u64 %d5,%d0,%d4;
    \\ mov.f32 %f0,0f00000000; mov.u32 %r5,%r3;
    \\ NORM_SUM: setp.ge.u32 %p0,%r5,%r0; @%p0 bra NORM_SUM_DONE;
    \\ mul.wide.u32 %d6,%r5,4; add.u64 %d7,%d5,%d6; ld.global.f32 %f1,[%d7]; add.f32 %f0,%f0,%f1; add.u32 %r5,%r5,256; bra NORM_SUM;
    \\ NORM_SUM_DONE: mov.u64 %d8,values; mul.wide.u32 %d9,%r3,4; add.u64 %d10,%d8,%d9; st.shared.f32 [%d10],%f0; bar.sync 0; mov.u32 %r6,128;
    \\ NORM_SUM_REDUCE: setp.ge.u32 %p1,%r3,%r6; @%p1 bra NORM_SUM_SKIP;
    \\ mul.wide.u32 %d11,%r6,4; add.u64 %d12,%d10,%d11; ld.shared.f32 %f1,[%d12]; add.f32 %f0,%f0,%f1; st.shared.f32 [%d10],%f0;
    \\ NORM_SUM_SKIP: bar.sync 0; shr.u32 %r6,%r6,1; setp.ne.u32 %p2,%r6,0; @%p2 bra NORM_SUM_REDUCE;
    \\ ld.shared.f32 %f2,[%d8]; cvt.rn.f32.u32 %f3,%r0; div.rn.f32 %f2,%f2,%f3; bar.sync 0;
    \\ mov.f32 %f0,0f00000000; mov.u32 %r5,%r3;
    \\ NORM_VAR: setp.ge.u32 %p0,%r5,%r0; @%p0 bra NORM_VAR_DONE;
    \\ mul.wide.u32 %d6,%r5,4; add.u64 %d7,%d5,%d6; ld.global.f32 %f1,[%d7]; sub.f32 %f1,%f1,%f2; mul.f32 %f1,%f1,%f1; add.f32 %f0,%f0,%f1; add.u32 %r5,%r5,256; bra NORM_VAR;
    \\ NORM_VAR_DONE: st.shared.f32 [%d10],%f0; bar.sync 0; mov.u32 %r6,128;
    \\ NORM_VAR_REDUCE: setp.ge.u32 %p1,%r3,%r6; @%p1 bra NORM_VAR_SKIP;
    \\ mul.wide.u32 %d11,%r6,4; add.u64 %d12,%d10,%d11; ld.shared.f32 %f1,[%d12]; add.f32 %f0,%f0,%f1; st.shared.f32 [%d10],%f0;
    \\ NORM_VAR_SKIP: bar.sync 0; shr.u32 %r6,%r6,1; setp.ne.u32 %p2,%r6,0; @%p2 bra NORM_VAR_REDUCE;
    \\ ld.shared.f32 %f4,[%d8]; div.rn.f32 %f4,%f4,%f3; add.f32 %f4,%f4,0f3727C5AC; rsqrt.approx.ftz.f32 %f4,%f4;
    \\ mov.u32 %r5,%r3;
    \\ NORM_OUT: setp.ge.u32 %p0,%r5,%r0; @%p0 bra NORM_END;
    \\ mul.wide.u32 %d6,%r5,4; add.u64 %d7,%d5,%d6; ld.global.f32 %f1,[%d7]; sub.f32 %f1,%f1,%f2; mul.f32 %f1,%f1,%f4;
    \\ add.u64 %d13,%d1,%d6; add.u64 %d14,%d2,%d6; ld.global.f32 %f5,[%d13]; ld.global.f32 %f6,[%d14]; mul.f32 %f1,%f1,%f5; add.f32 %f1,%f1,%f6;
    \\ add.u32 %r7,%r4,%r5; setp.eq.u32 %p3,%r1,0; @%p3 bra NORM_FLOAT;
    \\ mul.wide.u32 %d15,%r7,2; add.u64 %d16,%d3,%d15; cvt.rn.f16.f32 %h,%f1; st.global.b16 [%d16],%h; bra NORM_NEXT;
    \\ NORM_FLOAT: mul.wide.u32 %d15,%r7,4; add.u64 %d16,%d3,%d15; st.global.f32 [%d16],%f1;
    \\ NORM_NEXT: add.u32 %r5,%r5,256; bra NORM_OUT;
    \\ NORM_END: ret;
    \\}
;
