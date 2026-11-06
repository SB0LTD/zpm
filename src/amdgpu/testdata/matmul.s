; C = A x B, n x n fp32, row-major, n a multiple of 16. One C element per
; work-item, 16 x 16 workgroups (four waves); 16 x 16 tiles of A and B are
; staged in LDS between barriers. v_mac_f32 sums in k order.
; kernargs: A (8), B (8), C (8), n (4)
.amdhsa_user_sgpr_kernarg_segment_ptr 1
.amdhsa_system_sgpr_workgroup_id_x 1
.amdhsa_system_sgpr_workgroup_id_y 1
.amdhsa_system_vgpr_workitem_id 1
.amdhsa_group_segment_fixed_size 2048
.amdhsa_kernarg_size 28
.amdhsa_next_free_vgpr 20
.amdhsa_next_free_sgpr 15
.amdhsa_reserve_vcc 1
.amdhsa_reserve_flat_scratch 0
.workgroup_size 16 16 1
    s_load_dwordx4 s[4:7], s[0:1], 0x0      ; A, B
    s_load_dwordx2 s[8:9], s[0:1], 0x10     ; C
    s_load_dword s10, s[0:1], 0x18          ; n
    s_mov_b32 m0, -1                        ; LDS: no limit
    s_lshl_b32 s11, s3, 4                   ; workgroup y * 16
    s_lshl_b32 s12, s2, 4                   ; workgroup x * 16
    v_add_u32_e32 v2, vcc, s11, v1          ; row
    v_add_u32_e32 v3, vcc, s12, v0          ; col
    v_lshlrev_b32_e32 v4, 4, v1
    v_add_u32_e32 v4, vcc, v4, v0
    v_lshlrev_b32_e32 v4, 2, v4             ; (ty * 16 + tx) * 4: this item's LDS slot
    v_lshlrev_b32_e32 v5, 6, v1             ; ty * 64: row ty of the A tile
    v_lshlrev_b32_e32 v6, 2, v0             ; tx * 4: column tx of the B tile
    v_mov_b32_e32 v7, 0                     ; the sum
    s_mov_b32 s13, 0                        ; k0
    s_waitcnt lgkmcnt(0)
tile:
    v_mul_lo_u32 v8, v2, s10                ; A[row][k0 + tx]
    v_add_u32_e32 v8, vcc, s13, v8
    v_add_u32_e32 v8, vcc, v8, v0
    v_lshlrev_b32_e32 v8, 2, v8
    v_mov_b32_e32 v9, s5
    v_add_u32_e32 v10, vcc, s4, v8
    v_addc_u32_e32 v11, vcc, 0, v9, vcc
    flat_load_dword v12, v[10:11]
    v_add_u32_e32 v8, vcc, s13, v1          ; B[k0 + ty][col]
    v_mul_lo_u32 v8, v8, s10
    v_add_u32_e32 v8, vcc, v8, v3
    v_lshlrev_b32_e32 v8, 2, v8
    v_mov_b32_e32 v9, s7
    v_add_u32_e32 v13, vcc, s6, v8
    v_addc_u32_e32 v14, vcc, 0, v9, vcc
    flat_load_dword v15, v[13:14]
    s_waitcnt vmcnt(0) lgkmcnt(0)
    ds_write_b32 v4, v12
    ds_write_b32 v4, v15 offset:1024
    s_waitcnt lgkmcnt(0)
    s_barrier
    v_mov_b32_e32 v16, v5
    v_mov_b32_e32 v17, v6
    s_mov_b32 s14, 16
inner:
    ds_read_b32 v18, v16
    ds_read_b32 v19, v17 offset:1024
    s_waitcnt lgkmcnt(0)
    v_mac_f32_e32 v7, v18, v19
    v_add_u32_e32 v16, vcc, 4, v16
    v_add_u32_e32 v17, vcc, 64, v17
    s_sub_u32 s14, s14, 1
    s_cmp_lg_u32 s14, 0
    s_cbranch_scc1 inner
    s_barrier
    s_add_u32 s13, s13, 16
    s_cmp_lt_u32 s13, s10
    s_cbranch_scc1 tile
    v_mul_lo_u32 v8, v2, s10                ; C[row][col]
    v_add_u32_e32 v8, vcc, v8, v3
    v_lshlrev_b32_e32 v8, 2, v8
    v_mov_b32_e32 v9, s9
    v_add_u32_e32 v10, vcc, s8, v8
    v_addc_u32_e32 v11, vcc, 0, v9, vcc
    flat_store_dword v[10:11], v7
    s_endpgm
