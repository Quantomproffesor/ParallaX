;maybe this file is a more appropiate/easier file for testing itsbased onn the same principle as audit


BITS 64
DEFAULT REL
GLOBAL _start

; ============================================================
;  FRACTAL PYRAMID FOLD / UNFOLD
;  16 bytes -> 1 tag -> 16 bytes
;  Alphabet: {2,4,6,8}
;  Pairing : Szudzik
;  Guidance: LUT ranking
; ============================================================

SECTION .bss
work_a      resq 128
work_b      resq 128
final_tag   resq 1

x           resq 1
y           resq 1
tag         resq 1

SECTION .data
; ------------------------------------------------------------
; Example LUT for layer (illustrative, real one generated offline)
; domain sparse by construction
; ------------------------------------------------------------
lut_used_L1 dq 8,12,20,35,80
lut_used_L1_count equ 5

start_bytes db 16 dup(0xE4)   ; demo input

SECTION .text

_start:
    lea rsi, [start_bytes]
    lea rdi, [work_a]
    call bytes_to_tags        ; 16 bytes -> 32 tags

    mov rcx, 32
    lea rsi, [work_a]
    lea rdi, [work_b]
    call fold_pyramid
    mov [final_tag], rax

    ; unfold back
    mov rax, [final_tag]
    lea rsi, [work_a]
    lea rdi, [work_b]
    call unfold_pyramid

    mov rax, 60
    xor rdi, rdi
    syscall

; ============================================================
; BYTE -> 2 TAGS (bitpairs -> {2,4,6,8} -> Szudzik)
; ============================================================
bytes_to_tags:
    mov rcx, 16
.next:
    lodsb
    mov ah, al
    shr ah, 4
    and al, 0x0F

    call nibble_to_pair
    call store_pair

    mov al, ah
    call nibble_to_pair
    call store_pair

    loop .next
    ret

nibble_to_pair:
    ; AL: 4 bits -> BL,BH in {2,4,6,8}
    mov bl, al
    and bl, 3
    call set_even
    mov bh, al
    shr bh, 2
    and bh, 3
    mov al, bh
    call set_even
    ret

set_even:
    cmp al, 0
    je .z
    cmp al, 1
    je .o
    cmp al, 2
    je .t
    mov al, 8
    ret
.z: mov al, 2
    ret
.o: mov al, 6
    ret
.t: mov al, 4
    ret

store_pair:
    movzx rax, bl
    movzx rbx, bh
    call szudzik_pair
    mov rax, [tag]
    stosq
    ret

; ============================================================
; PYRAMID FOLD (in situ)
; ============================================================
fold_pyramid:
.fold:
    cmp rcx, 1
    jbe .done
    xor rdx, rdx
.next:
    mov rax, [rsi + rdx*8]
    mov rbx, [rsi + rdx*8 + 8]
    call szudzik_pair
    call lut_rank_L1
    mov [rdi], rax
    add rdi, 8
    add rdx, 2
    cmp rdx, rcx
    jb .next
    shr rcx, 1
    xchg rsi, rdi
    jmp .fold
.done:
    mov rax, [rsi]
    ret

; ============================================================
; PYRAMID UNFOLD
; ============================================================
unfold_pyramid:
    mov rcx, 1
    mov [rsi], rax
.rev:
    cmp rcx, 32
    jae .done
    xor rdx, rdx
.nextu:
    mov rax, [rsi + rdx*8]
    call lut_unrank_L1
    call szudzik_unpair
    mov [rdi], rax
    mov [rdi+8], rbx
    add rdi, 16
    inc rdx
    cmp rdx, rcx
    jb .nextu
    shl rcx, 1
    xchg rsi, rdi
    jmp .rev
.done:
    ret

; ============================================================
; LUT GUIDANCE (ranking)
; ============================================================
lut_rank_L1:
    xor rcx, rcx
.loop:
    cmp rcx, lut_used_L1_count
    jae .fail
    cmp [lut_used_L1 + rcx*8], rax
    je .ok
    inc rcx
    jmp .loop
.ok:
    mov rax, rcx
    ret
.fail:
    ud2

lut_unrank_L1:
    mov rax, [lut_used_L1 + rax*8]
    ret

; ============================================================
; SZUDZIK PAIR / UNPAIR
; ============================================================
szudzik_pair:
    mov rcx, rax
    cmp rax, rbx
    jae .ge
    mov rax, rbx
    mul rbx
    add rax, rcx
    mov [tag], rax
    ret
.ge:
    mul rcx
    add rax, rcx
    add rax, rbx
    mov [tag], rax
    ret

szudzik_unpair:
    mov rdi, rax
    call isqrt_u64
    mov rcx, rax
    mul rcx
    sub rdi, rax
    cmp rdi, rcx
    jb .c1
    mov rax, rcx
    mov rbx, rdi
    sub rbx, rcx
    ret
.c1:
    mov rax, rdi
    mov rbx, rcx
    ret

; ============================================================
; INTEGER SQRT
; ============================================================
isqrt_u64:
    xor rcx, rcx
    mov rdx, 1
    shl rdx, 62
.a:
    cmp rdx, rax
    jbe .b
    shr rdx, 2
    jmp .a
.b:
    test rdx, rdx
    jz .done
    mov rbx, rcx
    add rbx, rdx
    cmp rax, rbx
    jb .s
    sub rax, rbx
    shr rcx, 1
    add rcx, rdx
    jmp .n
.s:
    shr rcx, 1
.n:
    shr rdx, 2
    jmp .b
.done:
    mov rax, rcx
    ret
