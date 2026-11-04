; dst[i] = src[i] for i < count, through buffer resources: the lanes past
; count read 0 and write nothing (the V# range check).
; kernargs: src (8), dst (8), count (4)
.amdhsa_user_sgpr_kernarg_segment_ptr 1
.amdhsa_system_sgpr_workgroup_id_x 1
.amdhsa_kernarg_size 20
.amdhsa_next_free_vgpr 3
.amdhsa_next_free_sgpr 20
.amdhsa_reserve_vcc 1
.amdhsa_reserve_flat_scratch 0
.workgroup_size 64 1 1
    s_load_dwordx4 s[4:7], s[0:1], 0x0      ; src, dst
    s_load_dword s8, s[0:1], 0x10           ; count (dwords)
    s_waitcnt lgkmcnt(0)
    s_lshl_b32 s14, s8, 2                   ; num_records: bytes
    s_mov_b32 s12, s4
    s_and_b32 s13, s5, 0xffff               ; base[47:32], stride 0
    s_mov_b32 s15, 0x27fac                  ; x y z w, FLOAT, 32
    s_mov_b32 s16, s6
    s_and_b32 s17, s7, 0xffff
    s_mov_b32 s18, s14
    s_mov_b32 s19, s15
    s_lshl_b32 s9, s2, 6                    ; the workgroup's first item
    v_add_u32_e32 v1, vcc, s9, v0
    v_lshlrev_b32_e32 v1, 2, v1             ; byte offset
    buffer_load_dword v2, v1, s[12:15], 0 offen
    s_waitcnt vmcnt(0)
    buffer_store_dword v2, v1, s[16:19], 0 offen
    s_endpgm
