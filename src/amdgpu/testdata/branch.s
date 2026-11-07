; out[i] = i odd ? i * 3 : i + 100, as an if/else under EXEC.
; kernargs: out (8)
.amdhsa_user_sgpr_kernarg_segment_ptr 1
.amdhsa_kernarg_size 8
.amdhsa_next_free_vgpr 6
.amdhsa_next_free_sgpr 8
.amdhsa_reserve_vcc 1
.amdhsa_reserve_flat_scratch 0
.workgroup_size 64 1 1
    s_load_dwordx2 s[4:5], s[0:1], 0x0
    v_and_b32_e32 v1, 1, v0
    v_cmp_eq_u32_e32 vcc, 1, v1
    s_and_saveexec_b64 s[6:7], vcc          ; then: the odd lanes
    s_cbranch_execz else_part
    v_mul_u32_u24_e32 v2, 3, v0
else_part:
    s_xor_b64 exec, exec, s[6:7]            ; else: the others
    v_add_u32_e32 v2, vcc, 0x64, v0
    s_or_b64 exec, exec, s[6:7]
    v_lshlrev_b32_e32 v3, 2, v0
    s_waitcnt lgkmcnt(0)
    v_mov_b32_e32 v5, s5
    v_add_u32_e32 v4, vcc, s4, v3
    v_addc_u32_e32 v5, vcc, 0, v5, vcc
    flat_store_dword v[4:5], v2
    s_endpgm
