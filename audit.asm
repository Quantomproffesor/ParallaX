          TODO.MD:

; ARCHITECTURE: x86_64 LINUX
; NO LIBRARIES. PURE KERNEL INTERACTION.
; LOGIC: LIVE BIJECTIVE AUDIT

global _start

section .data
    ; HARDCODED FACTORS
    factor_lvl2 dq 1
    factor_lvl4 dq 1
    factor_lvl6 dq 1

    ; BIT MAP LUT (00->2, 01->6, 10->4, 11->8)
    map_lut db 2, 6, 4, 8

    ; TELEMETRY TEMPLATES
    msg_header db "--- PIPELINE V2 LIVE AUDIT ---", 10, 0
    len_header equ $ - msg_header
    
    lbl_seq    db "SEQ: ", 0
    lbl_in     db "IN : ", 0
    lbl_tag    db "TAG: ", 0
    lbl_out    db "REC: ", 0
    lbl_ok     db " [OK]", 10, "----------------", 10, 0
    lbl_fail   db " [FAIL] !!! CRITICAL ANOMALY !!!", 10, 0
    
    err_args   db "Usage: ./audit <input_file>", 10, 0
    err_open   db "Error: Cannot open input file.", 10, 0

    newline    db 10

section .bss
    fd_in      resd 1
    len_in     resq 1
    ptr_in     resq 1
    st_in      resb 144
    
    ; PIPELINE BUFFERS
    lvl0       resq 64
    lvl1       resq 32
    lvl2       resq 16
    lvl3       resq 8
    lvl4       resq 4
    lvl5       resq 2
    lvl6       resq 1   ; The Tag
    
    recovered  resb 16  ; Unfolded Bytes
    
    ; PRINT BUFFERS
    num_buf    resb 64
    hex_buf    resb 3

section .text

_start:
    ; --- INIT FACTORS ---
    mov qword [factor_lvl2], 80
    mov qword [factor_lvl4], 6320
    mov qword [factor_lvl6], 39702600

    ; --- PRINT HEADER ---
    mov rsi, msg_header
    mov rdx, len_header
    call sys_print_raw

    ; --- ARGUMENT CHECK ---
    mov rcx, [rsp]
    cmp rcx, 2
    jl .exit_usage
    
    mov rdi, [rsp+16]

    ; --- OPEN FILE ---
    mov rax, 2      ; sys_open
    mov rsi, 0      ; O_RDONLY
    mov rdx, 0
    syscall
    test rax, rax
    js .exit_open
    mov [fd_in], eax

    ; --- GET SIZE ---
    mov rax, 5      ; sys_fstat
    mov rdi, [fd_in]
    lea rsi, [st_in]
    syscall
    mov rax, [st_in + 48]
    mov [len_in], rax

    ; --- MMAP INPUT ---
    mov rax, 9      ; sys_mmap
    mov rdi, 0
    mov rsi, [len_in]
    mov rdx, 1      ; PROT_READ
    mov r10, 2      ; MAP_PRIVATE
    mov r8, [fd_in]
    mov r9, 0
    syscall
    cmp rax, -1
    je .exit_open
    mov [ptr_in], rax

    ; ==========================================================
    ; MAIN AUDIT LOOP
    ; ==========================================================
    xor r15, r15    ; SEQUENCE COUNTER (Chunk Index)
    mov r14, [ptr_in] ; Current Read Pointer
    mov r13, [len_in] ; Bytes Remaining
    
.audit_loop:
    cmp r13, 16
    jl .audit_done  ; Ignore trailing bytes < 16 (Strict Padding Rules?)
                    ; Or we could pad. For now, strict 16 check.

    ; -----------------------------------------
    ; 1. TELEMETRY: SEQ
    ; -----------------------------------------
    mov rsi, lbl_seq
    call print_str
    mov rax, r15
    call print_dec
    mov rsi, newline
    call print_str

    ; -----------------------------------------
    ; 2. TELEMETRY: INPUT BYTES
    ; -----------------------------------------
    mov rsi, lbl_in
    call print_str
    mov rsi, r14
    call print_hex_16
    mov rsi, newline
    call print_str

    ; -----------------------------------------
    ; 3. ACTION: FOLD
    ; -----------------------------------------
    ; Input at R14. Result goes to [lvl6] and RAX
    mov rsi, r14
    call core_fold
    mov [lvl6], rax ; Save Tag

    ; -----------------------------------------
    ; 4. TELEMETRY: TAG
    ; -----------------------------------------
    mov rsi, lbl_tag
    call print_str
    mov rax, [lvl6]
    call print_dec
    mov rsi, newline
    call print_str

    ; -----------------------------------------
    ; 5. ACTION: UNFOLD
    ; -----------------------------------------
    ; Input from [lvl6]. Result to [recovered]
    call core_unfold

    ; -----------------------------------------
    ; 6. TELEMETRY: RECOVERED BYTES
    ; -----------------------------------------
    mov rsi, lbl_out
    call print_str
    lea rsi, [recovered]
    call print_hex_16
    
    ; -----------------------------------------
    ; 7. ACTION: VERIFY (IN SITU CHECK)
    ; -----------------------------------------
    mov rsi, r14        ; Original
    lea rdi, [recovered] ; Unfolded
    mov rcx, 16
    repe cmpsb          ; Compare 16 bytes
    jne .integrity_fail

    ; SUCCESS
    mov rsi, lbl_ok
    call print_str
    jmp .next_chunk

.integrity_fail:
    mov rsi, lbl_fail
    call print_str
    ; STOP ON ERROR? 
    ; "TRACK ANY ANOMALIES". We continue, or exit? 
    ; Critical failure usually demands halt to preserve logs.
    jmp .exit_cleanup

.next_chunk:
    add r14, 16
    sub r13, 16
    inc r15
    jmp .audit_loop

.audit_done:
    ; --- CLEANUP ---
.exit_cleanup:
    mov rax, 11     ; munmap
    mov rdi, [ptr_in]
    mov rsi, [len_in]
    syscall
    
    mov rax, 3      ; close
    mov rdi, [fd_in]
    syscall
    
    mov rax, 60     ; exit
    xor rdi, rdi
    syscall

.exit_usage:
    mov rsi, err_args
    call print_str
    mov rax, 60
    mov rdi, 1
    syscall

.exit_open:
    mov rsi, err_open
    call print_str
    mov rax, 60
    mov rdi, 1
    syscall


; ==========================================================
; KERNEL: FOLD ENGINE
; ==========================================================
core_fold:
    ; Input: RSI (Ptr to 16 bytes)
    ; Output: RAX (Tag)
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    
    ; 1. BYTES -> BITPAIRS (LVL0)
    lea rbx, [map_lut]
    lea rdi, [lvl0]
    xor rcx, rcx
.b_loop:
    movzx rax, byte [rsi + rcx]
    ; Pair 3
    mov rdx, rax
    shr rdx, 6
    and rdx, 3
    movzx r8, byte [rbx + rdx]
    mov [rdi], r8
    ; Pair 2
    mov rdx, rax
    shr rdx, 4
    and rdx, 3
    movzx r8, byte [rbx + rdx]
    mov [rdi+8], r8
    ; Pair 1
    mov rdx, rax
    shr rdx, 2
    and rdx, 3
    movzx r8, byte [rbx + rdx]
    mov [rdi+16], r8
    ; Pair 0
    mov rdx, rax
    and rdx, 3
    movzx r8, byte [rbx + rdx]
    mov [rdi+24], r8
    
    add rdi, 32
    inc rcx
    cmp rcx, 16
    jne .b_loop

    ; 2. SZUDZIK (LVL0 -> LVL1)
    lea rsi, [lvl0]
    lea rdi, [lvl1]
    mov rcx, 32
    call proc_szudzik

    ; 3. QCH 80 (LVL1 -> LVL2)
    lea rsi, [lvl1]
    lea rdi, [lvl2]
    mov rdx, [factor_lvl2]
    mov rcx, 16
    call proc_qch

    ; 4. SZUDZIK (LVL2 -> LVL3)
    lea rsi, [lvl2]
    lea rdi, [lvl3]
    mov rcx, 8
    call proc_szudzik

    ; 5. QCH 6320 (LVL3 -> LVL4)
    lea rsi, [lvl3]
    lea rdi, [lvl4]
    mov rdx, [factor_lvl4]
    mov rcx, 4
    call proc_qch

    ; 6. SZUDZIK (LVL4 -> LVL5)
    lea rsi, [lvl4]
    lea rdi, [lvl5]
    mov rcx, 2
    call proc_szudzik

    ; 7. QCH 39M (LVL5 -> RAX)
    lea rsi, [lvl5]
    mov rax, [rsi]
    mov rbx, [rsi+8]
    mov rdx, [factor_lvl6]
    call math_qch_pair

    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ==========================================================
; KERNEL: UNFOLD ENGINE
; ==========================================================
core_unfold:
    ; Input: [lvl6] (Tag)
    ; Output: [recovered] (16 bytes)
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    
    ; 1. UNPAIR LVL6 -> LVL5
    mov rax, [lvl6]
    mov rdx, [factor_lvl6]
    call math_qch_unpair
    mov [lvl5], rbx
    mov [lvl5+8], rcx

    ; 2. UNPAIR LVL5 -> LVL4 (Szudzik)
    lea rsi, [lvl5]
    lea rdi, [lvl4]
    mov rcx, 2
    call proc_un_szudzik

    ; 3. UNPAIR LVL4 -> LVL3 (QCH 6320)
    lea rsi, [lvl4]
    lea rdi, [lvl3]
    mov rdx, [factor_lvl4]
    mov rcx, 4
    call proc_un_qch

    ; 4. UNPAIR LVL3 -> LVL2 (Szudzik)
    lea rsi, [lvl3]
    lea rdi, [lvl2]
    mov rcx, 8
    call proc_un_szudzik

    ; 5. UNPAIR LVL2 -> LVL1 (QCH 80)
    lea rsi, [lvl2]
    lea rdi, [lvl1]
    mov rdx, [factor_lvl2]
    mov rcx, 16
    call proc_un_qch

    ; 6. UNPAIR LVL1 -> LVL0 (Szudzik)
    lea rsi, [lvl1]
    lea rdi, [lvl0]
    mov rcx, 32
    call proc_un_szudzik

    ; 7. RECONSTRUCT BYTES
    lea rsi, [lvl0]
    lea rdi, [recovered]
    xor rcx, rcx
.pack_loop:
    xor rbx, rbx
    ; Pair 3
    mov rax, [rsi]
    call util_unmap
    shl rax, 6
    or rbx, rax
    add rsi, 8
    ; Pair 2
    mov rax, [rsi]
    call util_unmap
    shl rax, 4
    or rbx, rax
    add rsi, 8
    ; Pair 1
    mov rax, [rsi]
    call util_unmap
    shl rax, 2
    or rbx, rax
    add rsi, 8
    ; Pair 0
    mov rax, [rsi]
    call util_unmap
    or rbx, rax
    add rsi, 8
    
    mov [rdi + rcx], bl
    inc rcx
    cmp rcx, 16
    jne .pack_loop

    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ==========================================================
; MATH PRIMITIVES (INLINE OPTIMIZED)
; ==========================================================

proc_szudzik: ; RCX=Count, RSI=In, RDI=Out
.loop:
    push rcx
    mov rax, [rsi]
    mov rbx, [rsi+8]
    call math_szudzik_pair
    mov [rdi], rax
    add rsi, 16
    add rdi, 8
    pop rcx
    loop .loop
    ret

proc_qch: ; RCX=Count, RSI=In, RDI=Out, RDX=Factor
    mov r8, rdx
.loop:
    push rcx
    mov rax, [rsi]
    mov rbx, [rsi+8]
    mov rdx, r8
    call math_qch_pair
    mov [rdi], rax
    add rsi, 16
    add rdi, 8
    pop rcx
    loop .loop
    ret

proc_un_szudzik:
.loop:
    push rcx
    mov rax, [rsi]
    call math_szudzik_unpair
    mov [rdi], rbx
    mov [rdi+8], rcx
    add rsi, 8
    add rdi, 16
    pop rcx
    loop .loop
    ret

proc_un_qch:
    mov r8, rdx
.loop:
    push rcx
    mov rax, [rsi]
    mov rdx, r8
    call math_qch_unpair
    mov [rdi], rbx
    mov [rdi+8], rcx
    add rsi, 8
    add rdi, 16
    pop rcx
    loop .loop
    ret

math_szudzik_pair:
    cmp rax, rbx
    jae .ge
    mov r9, rax
    mov rax, rbx
    mul rbx
    add rax, r9
    ret
.ge:
    mov r9, rbx
    mov rbx, rax
    mul rbx
    add rax, rbx
    add rax, r9
    ret

math_szudzik_unpair: ; In: RAX. Out: RBX(X), RCX(Y)
    push rdx
    push rdi
    mov r11, rax
    mov r8, r11
    xor rdi, rdi
    mov r9, 1
    shl r9, 62
.sqrt:
    cmp r9, r8
    ja .skip
    mov r10, rdi
    add r10, r9
    cmp r8, r10
    jb .else
    sub r8, r10
    shr rdi, 1
    add rdi, r9
    jmp .next
.else:
    shr rdi, 1
.next:
    .skip:
    shr r9, 2
    test r9, r9
    jnz .sqrt
    
    mov rax, rdi
    mul rdi
    mov rdx, r11
    sub rdx, rax
    cmp rdx, rdi
    jae .case2
    mov rbx, rdx
    mov rcx, rdi
    jmp .done
.case2:
    sub rdx, rdi
    mov rbx, rdi
    mov rcx, rdx
.done:
    pop rdi
    pop rdx
    ret

math_qch_pair: ; rax=y, rbx=x, rdx=F. Out: rax = y*F + x
    mul rdx      ; rax = y * F
    add rax, rbx ; rax = y * F + x
    ret

math_qch_unpair: ; In: rax=w, rdx=F. Out: rbx=x, rcx=y
    ; w = y*F + x
    ; y = w / F (quotient)
    ; x = w % F (remainder)
    mov r9, rdx   ; Copy factor F to r9, because div uses rdx for remainder
    xor rdx, rdx  ; Clear rdx for 128-bit division (rdx:rax)
    div r9        ; rax = rax / r9 (quotient), rdx = rax % r9 (remainder)
    mov rcx, rax  ; y = quotient
    mov rbx, rdx  ; x = remainder
    ret

util_unmap:
    cmp rax, 2
    je .0
    cmp rax, 6
    je .1
    cmp rax, 4
    je .2
    mov rax, 3
    ret
.0: xor rax, rax
    ret
.1: mov rax, 1
    ret
.2: mov rax, 2
    ret

; ==========================================================
; I/O UTILS
; ==========================================================
print_str: ; RSI = String
    push rdi
    push rdx
    push rcx
    push rax
    ; Count len
    mov rdx, 0
.len:
    cmp byte [rsi+rdx], 0
    je .print
    inc rdx
    jmp .len
.print:
    mov rax, 1
    mov rdi, 1
    syscall
    pop rax
    pop rcx
    pop rdx
    pop rdi
    ret

sys_print_raw: ; RSI=Str, RDX=Len
    mov rax, 1
    mov rdi, 1
    syscall
    ret

print_dec: ; RAX = Number
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    
    mov rcx, num_buf
    add rcx, 63
    mov byte [rcx], 0
    mov rbx, 10
.loop:
    xor rdx, rdx
    div rbx
    add dl, '0'
    dec rcx
    mov [rcx], dl
    test rax, rax
    jnz .loop
    
    mov rsi, rcx
    call print_str
    
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

print_hex_16: ; RSI = Pointer to 16 bytes
    push rcx
    push rsi
    mov rcx, 16
.loop:
    movzx rax, byte [rsi]
    call print_hex_byte
    ; Print space
    push rax
    push rdi
    push rdx
    push rsi
    mov rax, 1
    mov rdi, 1
    lea rsi, [hex_buf+2] ; Hack for space
    mov byte [rsi], ' '
    mov rdx, 1
    syscall
    pop rsi
    pop rdx
    pop rdi
    pop rax
    
    inc rsi
    dec rcx
    jnz .loop
    pop rsi
    pop rcx
    ret

print_hex_byte: ; RAX = Byte
    push rax
    push rbx
    push rdx
    push rdi
    push rsi
    
    mov rbx, rax
    
    ; High nibble
    shr rax, 4
    call .char
    mov [hex_buf], al
    
    ; Low nibble
    mov rax, rbx
    and rax, 0xF
    call .char
    mov [hex_buf+1], al
    
    mov rax, 1
    mov rdi, 1
    lea rsi, [hex_buf]
    mov rdx, 2
    syscall
    
    pop rsi
    pop rdi
    pop rdx
    pop rbx
    pop rax
    ret
.char:
    cmp al, 9
    jg .alpha
    add al, '0'
    ret
.alpha:
    add al, 'A'-10
    ret
