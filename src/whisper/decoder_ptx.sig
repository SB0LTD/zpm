//! One query per head, one CTA per head. K/V are borrowed, time-major F16
//! arrays. Products accumulate in F32; softmax probabilities round to F16,
//! matching the checked GGML attention contract. No external compiler needed.
pub const source =
    \\.visible .entry whisper_decoder_attention(
    \\ .param .u64 query, .param .u64 keys, .param .u64 values, .param .u64 output,
    \\ .param .u32 count, .param .u32 state, .param .u32 head_dim, .param .f32 scale) {
    \\ .reg .pred %p<8>;
    \\ .reg .b16 %h;
    \\ .reg .b32 %r<20>;
    \\ .reg .b64 %rd<24>;
    \\ .reg .f32 %f<16>;
    \\ .shared .align 4 .b8 scores[16384];
    \\ .shared .align 4 .b8 reduction[512];
    \\ .shared .align 4 .b8 queries[512];
    \\ ld.param.u64 %rd0,[query];
    \\ ld.param.u64 %rd1,[keys];
    \\ ld.param.u64 %rd2,[values];
    \\ ld.param.u64 %rd3,[output];
    \\ ld.param.u32 %r0,[count];
    \\ ld.param.u32 %r1,[state];
    \\ ld.param.u32 %r2,[head_dim];
    \\ ld.param.f32 %f0,[scale];
    \\ mov.u32 %r3,%ctaid.x;
    \\ mov.u32 %r4,%tid.x;
    \\ mul.lo.u32 %r5,%r3,%r2;
    \\ mov.u64 %rd4,scores;
    \\ mov.u64 %rd5,reduction;
    \\ mov.u64 %rd6,queries;
    \\ mul.wide.u32 %rd7,%r4,4;
    \\ add.u64 %rd8,%rd5,%rd7;
    \\ setp.ge.u32 %p0,%r4,%r2;
    \\ @%p0 bra WDA_QUERY_DONE;
    \\ add.u32 %r6,%r5,%r4;
    \\ mul.wide.u32 %rd9,%r6,2;
    \\ add.u64 %rd10,%rd0,%rd9;
    \\ ld.global.b16 %h,[%rd10];
    \\ cvt.f32.f16 %f1,%h;
    \\ add.u64 %rd11,%rd6,%rd7;
    \\ st.shared.f32 [%rd11],%f1;
    \\ WDA_QUERY_DONE:
    \\ bar.sync 0;
    \\ mov.u32 %r7,%r4;
    \\ mov.f32 %f2,0fFF800000;
    \\ WDA_SCORE:
    \\ setp.ge.u32 %p1,%r7,%r0;
    \\ @%p1 bra WDA_SCORE_DONE;
    \\ mad.lo.u32 %r8,%r7,%r1,%r5;
    \\ mul.wide.u32 %rd9,%r8,2;
    \\ add.u64 %rd10,%rd1,%rd9;
    \\ mov.u64 %rd11,%rd6;
    \\ mov.u32 %r9,0;
    \\ mov.f32 %f3,0f00000000;
    \\ WDA_DOT:
    \\ ld.global.b16 %h,[%rd10];
    \\ cvt.f32.f16 %f4,%h;
    \\ ld.shared.f32 %f5,[%rd11];
    \\ fma.rn.f32 %f3,%f4,%f5,%f3;
    \\ add.u64 %rd10,%rd10,2;
    \\ add.u64 %rd11,%rd11,4;
    \\ add.u32 %r9,%r9,1;
    \\ setp.lt.u32 %p2,%r9,%r2;
    \\ @%p2 bra WDA_DOT;
    \\ mul.f32 %f3,%f3,%f0;
    \\ max.f32 %f2,%f2,%f3;
    \\ mul.wide.u32 %rd12,%r7,4;
    \\ add.u64 %rd13,%rd4,%rd12;
    \\ st.shared.f32 [%rd13],%f3;
    \\ add.u32 %r7,%r7,128;
    \\ bra WDA_SCORE;
    \\ WDA_SCORE_DONE:
    \\ st.shared.f32 [%rd8],%f2;
    \\ bar.sync 0;
    \\ mov.u32 %r10,64;
    \\ WDA_MAX:
    \\ setp.ge.u32 %p3,%r4,%r10;
    \\ @%p3 bra WDA_MAX_SKIP;
    \\ mul.wide.u32 %rd14,%r10,4;
    \\ add.u64 %rd15,%rd8,%rd14;
    \\ ld.shared.f32 %f4,[%rd15];
    \\ max.f32 %f2,%f2,%f4;
    \\ st.shared.f32 [%rd8],%f2;
    \\ WDA_MAX_SKIP:
    \\ bar.sync 0;
    \\ shr.u32 %r10,%r10,1;
    \\ setp.ne.u32 %p4,%r10,0;
    \\ @%p4 bra WDA_MAX;
    \\ ld.shared.f32 %f6,[%rd5];
    \\ bar.sync 0;
    \\ mov.u32 %r7,%r4;
    \\ mov.f32 %f7,0f00000000;
    \\ WDA_EXP:
    \\ setp.ge.u32 %p1,%r7,%r0;
    \\ @%p1 bra WDA_EXP_DONE;
    \\ mul.wide.u32 %rd12,%r7,4;
    \\ add.u64 %rd13,%rd4,%rd12;
    \\ ld.shared.f32 %f3,[%rd13];
    \\ sub.f32 %f3,%f3,%f6;
    \\ mul.f32 %f3,%f3,0f3FB8AA3B;
    \\ ex2.approx.ftz.f32 %f3,%f3;
    \\ st.shared.f32 [%rd13],%f3;
    \\ add.f32 %f7,%f7,%f3;
    \\ add.u32 %r7,%r7,128;
    \\ bra WDA_EXP;
    \\ WDA_EXP_DONE:
    \\ st.shared.f32 [%rd8],%f7;
    \\ bar.sync 0;
    \\ mov.u32 %r10,64;
    \\ WDA_SUM:
    \\ setp.ge.u32 %p3,%r4,%r10;
    \\ @%p3 bra WDA_SUM_SKIP;
    \\ mul.wide.u32 %rd14,%r10,4;
    \\ add.u64 %rd15,%rd8,%rd14;
    \\ ld.shared.f32 %f4,[%rd15];
    \\ add.f32 %f7,%f7,%f4;
    \\ st.shared.f32 [%rd8],%f7;
    \\ WDA_SUM_SKIP:
    \\ bar.sync 0;
    \\ shr.u32 %r10,%r10,1;
    \\ setp.ne.u32 %p4,%r10,0;
    \\ @%p4 bra WDA_SUM;
    \\ ld.shared.f32 %f8,[%rd5];
    \\ rcp.approx.ftz.f32 %f8,%f8;
    \\ mov.u32 %r7,%r4;
    \\ WDA_PROB:
    \\ setp.ge.u32 %p1,%r7,%r0;
    \\ @%p1 bra WDA_PROB_DONE;
    \\ mul.wide.u32 %rd12,%r7,4;
    \\ add.u64 %rd13,%rd4,%rd12;
    \\ ld.shared.f32 %f3,[%rd13];
    \\ mul.f32 %f3,%f3,%f8;
    \\ cvt.rn.f16.f32 %h,%f3;
    \\ cvt.f32.f16 %f3,%h;
    \\ st.shared.f32 [%rd13],%f3;
    \\ add.u32 %r7,%r7,128;
    \\ bra WDA_PROB;
    \\ WDA_PROB_DONE:
    \\ bar.sync 0;
    \\ setp.ge.u32 %p0,%r4,%r2;
    \\ @%p0 bra WDA_END;
    \\ add.u32 %r6,%r5,%r4;
    \\ mul.wide.u32 %rd9,%r6,2;
    \\ add.u64 %rd10,%rd2,%rd9;
    \\ mul.wide.u32 %rd16,%r1,2;
    \\ mov.u64 %rd11,%rd4;
    \\ mov.f32 %f9,0f00000000;
    \\ mov.u32 %r7,0;
    \\ WDA_VALUES:
    \\ ld.global.b16 %h,[%rd10];
    \\ cvt.f32.f16 %f4,%h;
    \\ ld.shared.f32 %f3,[%rd11];
    \\ fma.rn.f32 %f9,%f4,%f3,%f9;
    \\ add.u64 %rd10,%rd10,%rd16;
    \\ add.u64 %rd11,%rd11,4;
    \\ add.u32 %r7,%r7,1;
    \\ setp.lt.u32 %p1,%r7,%r0;
    \\ @%p1 bra WDA_VALUES;
    \\ mul.wide.u32 %rd17,%r6,4;
    \\ add.u64 %rd18,%rd3,%rd17;
    \\ st.global.f32 [%rd18],%f9;
    \\ WDA_END:
    \\ ret;
    \\}
;
