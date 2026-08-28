; ============================================================
; ENTRY  -  32 BIT KERNEL ENTRY AND PRIVILEGE CORE
; ============================================================
;
; Included by kernel.asm and emitted first, so kernel_entry is
; the byte sitting at 0x8000 that the bootloader jumps to.
;
; The CPU is ALREADY in 32 bit protected mode by the time we
; get here. The bootloader did the A20 gate, the first GDT and
; the CR0 switch, because 16 bit code can never be a linkable
; object file and had to leave the kernel entirely.
;
; What is left here still has no C equivalent:
;
;   - LGDT and LTR
;   - the far jump that reloads CS
;   - the fake IRET frame used to reach ring 3
;
; So this file stays assembly permanently.
; ============================================================

bits 32


; kmain lives in kernel.c

extern kmain

extern paging_init

extern __bss_start

extern __bss_end

global kernel_entry


; ============================================================
; KERNEL ENTRY POINT
; ============================================================

kernel_entry:

    call patch_tss_descriptor


    ; --------------------------------------------------------
    ; The bootloader's GDT got us here, but it only has a code
    ; and a data descriptor. Install our own, which also has
    ; the ring 3 descriptors and the TSS.
    ; --------------------------------------------------------

    lgdt [gdt_descriptor]


    ; A far jump is the only way to reload CS.

    jmp CODE_SEG:.reload


.reload:

    mov ax, DATA_SEG

    mov ds, ax

    mov es, ax

    mov fs, ax

    mov gs, ax

    mov ss, ax


    mov esp, KERNEL_STACK

    cld


    call zero_bss

    call copy_bootinfo


    ; --------------------------------------------------------
    ; Paging goes on here: after zero_bss, because the tables
    ; live in .bss, and before anything else of consequence.
    ; --------------------------------------------------------

    call paging_init


    call pic_remap

    call idt_init

    sti


    call splash


    ; --------------------------------------------------------
    ; First call into C. Everything from here can be written in
    ; either language; the linker no longer cares which.
    ; --------------------------------------------------------

    call kmain


    ; Everything from here on runs in ring 3 and can only reach
    ; the hardware by asking.

    jmp enter_user_mode


; ============================================================
; ZERO THE BSS
; ============================================================
;
; C assumes uninitialised globals start as zero. A flat binary
; stores no .bss on disk, so whatever the RAM happened to hold
; is what a C global would see. The assembly never cared,
; because it declared its variables with db/dd and they were
; part of the image.
; ============================================================

zero_bss:

    mov edi, __bss_start

    mov ecx, __bss_end

    sub ecx, edi

    xor al, al

    rep stosb

    ret


; ============================================================
; PATCH THE TSS DESCRIPTOR
; ============================================================
;
; A descriptor stores its base address split across three
; fields, one of which is 16 bits wide. Writing "dw tss_start"
; asks the assembler for a 16 bit relocation, and COFF object
; files cannot express one -- the same limitation that pushed
; all the 16 bit code out into the bootloader.
;
; So the fields are left zero and filled in here, where the
; address is just a number in a register.
;
; Descriptor layout:
;
;   +0 limit 0-15   +2 base 0-15   +4 base 16-23
;   +5 access       +6 flags       +7 base 24-31
; ============================================================

patch_tss_descriptor:

    mov eax, tss_start

    mov [gdt_tss + 2], ax       ; base 0-15

    shr eax, 16

    mov [gdt_tss + 4], al       ; base 16-23

    mov [gdt_tss + 7], ah       ; base 24-31

    ret


; ============================================================
; COLLECT WHAT THE BOOTLOADER LEARNED
; ============================================================
;
; BIOS can only be questioned in real mode, so the bootloader
; did the asking and left the answers at a fixed address. Copy
; them into the kernel's own variables so everything above this
; point can stay as it was.
; ============================================================

copy_bootinfo:

    mov ax, [BI_CONV]

    mov [mem_conv], ax


    mov ax, [BI_EXT_KB]

    mov [ext_kb], ax


    mov ax, [BI_EXT_BLK]

    mov [ext_blocks], ax


    mov ax, [BI_EQUIP]

    mov [equip], ax


    mov al, [BI_DRIVE]

    mov [boot_drive], al


    mov al, [BI_EDD_OK]

    mov [edd_ok], al


    mov esi, BI_EDD

    mov edi, edd_buf

    mov ecx, 26

    rep movsb

    ret


; ============================================================
; GLOBAL DESCRIPTOR TABLE
; ============================================================
;
; Six descriptors. Every segment is "flat": base 0, limit 4 GB,
; so a segment register no longer shifts addresses the way it
; did in real mode and an offset is simply an address.
;
; The ring 3 entries differ only in their DPL field. That two
; bit number is the whole of the privilege boundary.
; ============================================================

gdt_start:

gdt_null:

    dd 0

    dd 0


gdt_code:

    dw 0FFFFh                   ; limit 0-15

    dw 0                        ; base 0-15

    db 0                        ; base 16-23

    db 10011010b                ; present, ring 0, code, readable

    db 11001111b                ; 4 KB granularity, 32 bit

    db 0                        ; base 24-31


gdt_data:

    dw 0FFFFh

    dw 0

    db 0

    db 10010010b                ; present, ring 0, data, writable

    db 11001111b

    db 0


gdt_ucode:

    dw 0FFFFh

    dw 0

    db 0

    db 11111010b                ; present, DPL 3, code, readable

    db 11001111b

    db 0


gdt_udata:

    dw 0FFFFh

    dw 0

    db 0

    db 11110010b                ; present, DPL 3, data, writable

    db 11001111b

    db 0


; ------------------------------------------------------------
; Task State Segment descriptor.
;
; The CPU reads this when an interrupt arrives while running in
; ring 3, to find out which stack to switch to.
; ------------------------------------------------------------

gdt_tss:

    dw tss_end - tss_start - 1  ; limit

    dw 0                        ; base 0-15   ] filled in at run time
    db 0                        ; base 16-23  ] by patch_tss_descriptor

    db 10001001b                ; present, DPL 0, 32 bit TSS available

    db 0                        ; flags and limit 16-19

    db 0                        ; base 24-31  ]


gdt_end:


gdt_descriptor:

    dw gdt_end - gdt_start - 1  ; limit is size minus one

    dd gdt_start


; ============================================================
; TASK STATE SEGMENT
; ============================================================
;
; Only two fields matter here.
;
; esp0 / ss0 are the stack the CPU switches to when it enters
; ring 0 from ring 3. Without them an interrupt taken in user
; mode would keep using the user stack, which the user could
; have pointed anywhere.
;
; The I/O map base is set past the end of the TSS, which the
; CPU reads as "no I/O permitted at all". That is what makes
; IN and OUT fault in ring 3.
; ============================================================

tss_start:

    dd 0                        ; 0   previous task link

    dd KERNEL_STACK             ; 4   esp0

    dd DATA_SEG                 ; 8   ss0

    times 22 dd 0               ; 12..99

    dw 0                        ; 100 trap flag

    dw tss_end - tss_start      ; 102 I/O map base

tss_end:


; ============================================================
; ENTER USER MODE
; ============================================================
;
; There is no instruction for "drop to ring 3". The way in is
; to fake the stack frame an interrupt would have pushed when
; coming FROM ring 3, then IRET, and let the CPU return to a
; place it never actually came from.
; ============================================================

enter_user_mode:

    mov ax, TSS_SEG

    ltr ax                      ; tell the CPU where the TSS is


    mov ax, UDATA_SEG | 3

    mov ds, ax

    mov es, ax

    mov fs, ax

    mov gs, ax


    push dword UDATA_SEG | 3    ; SS

    push dword USER_STACK       ; ESP

    push dword 202h             ; EFLAGS, interrupts enabled

    push dword UCODE_SEG | 3    ; CS

    push dword shell_main       ; EIP

    iretd


;still not underatanding what shit is happening
