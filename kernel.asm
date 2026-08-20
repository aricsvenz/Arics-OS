; ============================================================
; KERNEL  -  32 BIT PROTECTED MODE, RING 0
; AUTHOR - AMOL SINGH (https://amolsingh.in) | aricsvenz@gmail.com
; ============================================================
;
; Loaded by the bootloader at 0000:8000, still in 16 bit
; real mode. Assembled together with shell.asm, which is
; included at the end and runs in ring 3.
;
;   1. Ask BIOS everything we will want to know later
;   2. Enable the A20 line
;   3. Build a Global Descriptor Table
;   4. Set the PE bit in CR0
;   5. Far jump into 32 bit code
;   6. Remap the PIC and build an Interrupt Descriptor Table
;   7. Run the shell
;
; IMPORTANT
;
; The moment CR0.PE is set, BIOS is gone. INT 10h, INT 13h and
; INT 16h are 16 bit real mode routines and cannot be called.
; Anything BIOS knows has to be collected BEFORE the switch,
; which is what bios_survey is for.
;
; The previous 16 bit OS is kept in backup/stage2_realmode.asm.
; ============================================================

; No org. The linker places us at 0x8000 now - see linker.ld.


; ============================================================
; GDT SELECTORS
; ============================================================

; A selector is a byte offset into the GDT. The low two bits
; are the Requested Privilege Level, so a ring 3 selector is
; the offset with 3 OR'd in.

CODE_SEG  equ gdt_code - gdt_start          ; 0x08  ring 0 code

DATA_SEG  equ gdt_data - gdt_start          ; 0x10  ring 0 data

UCODE_SEG equ gdt_ucode - gdt_start         ; 0x18  ring 3 code

UDATA_SEG equ gdt_udata - gdt_start         ; 0x20  ring 3 data

TSS_SEG   equ gdt_tss - gdt_start           ; 0x28  task state segment


KERNEL_STACK equ 0x90000

USER_STACK   equ 0x200000


; ============================================================
; VGA TEXT MODE
; ============================================================

VGA_MEM  equ 0xB8000

VGA_COLS equ 80

VGA_ROWS equ 25

CRTC_IDX equ 0x3D4

CRTC_DAT equ 0x3D5


; ============================================================
; INTERRUPT CONTROLLER
; ============================================================

PIC1_CMD  equ 0x20

PIC1_DATA equ 0x21

PIC2_CMD  equ 0xA0

PIC2_DATA equ 0xA1

PIC_EOI   equ 0x20

IRQ_BASE  equ 0x20

IDT_BASE  equ 0x6000

IDT_ENTRIES equ 256


; ============================================================
; KEYBOARD
; ============================================================

KBD_DATA  equ 0x60

KBD_CMD   equ 0x64

KBD_QUEUE_SIZE equ 32


; ============================================================
; SHELL BUFFERS
; ============================================================
;
; These live at 1 MB, which is only addressable because A20 is
; enabled. In real mode this address wrapped back to 0.
; ============================================================

; ============================================================
; BOOT INFORMATION BLOCK
; ============================================================
;
; Written by the bootloader while BIOS still existed. Layout is
; documented in boot.asm and must match it exactly.
; ============================================================

BOOTINFO    equ 0x7000

BI_CONV     equ BOOTINFO + 0

BI_EXT_KB   equ BOOTINFO + 2

BI_EXT_BLK  equ BOOTINFO + 4

BI_EQUIP    equ BOOTINFO + 6

BI_DRIVE    equ BOOTINFO + 8

BI_EDD_OK   equ BOOTINFO + 9

BI_EDD      equ BOOTINFO + 10


INPUT_BUF equ 0x100000

INPUT_MAX equ 1024

CPU_BUF   equ 0x100400

DIR_BUF   equ 0x100600

EDIT_BUF  equ 0x100800

EDIT_MAX  equ 2048


; ============================================================
; ATA PIO
; ============================================================
;
; The primary IDE channel. These are the same registers BIOS
; was driving on our behalf through INT 13h.
; ============================================================

ATA_DATA   equ 0x1F0

ATA_FEAT   equ 0x1F1

ATA_COUNT  equ 0x1F2

ATA_LBA0   equ 0x1F3

ATA_LBA1   equ 0x1F4

ATA_LBA2   equ 0x1F5

ATA_DRIVE  equ 0x1F6

ATA_CMD    equ 0x1F7                ; write: command

ATA_STATUS equ 0x1F7                ; read: status


ATA_BSY    equ 80h

ATA_DRQ    equ 08h

ATA_ERR    equ 01h


; ============================================================
; FILESYSTEM
; ============================================================
;
;   LBA 0        stage 1
;   LBA 1-32     stage 2
;   LBA 33       directory, one sector
;   LBA 34+      file data
;
; Directory entry, 16 bytes:
;
;   +0   flags      0 = free, 1 = used
;   +1   name[11]   NUL padded
;   +12  start_lba  word
;   +14  length     word
; ============================================================

DIR_LBA        equ 33

DATA_LBA       equ 34

FILE_SECTORS   equ 4                ; 2048 bytes per file

MAX_FILES      equ 16

DIR_ENTRY_SIZE equ 16

NAME_MAX       equ 11


; ------------------------------------------------------------
; Everything lands in one section.
;
; This is not optional for the object build: without an
; explicit section directive, NASM's win32 output emits every
; "global" symbol as UNDEFINED, and the link fails with
; undefined references to functions that are plainly right
; there in the file.
; ------------------------------------------------------------

section .text


%include "entry.asm"


; ============================================================
; KERNEL SERVICE: WAIT FOR A KEY
; ============================================================
;
; Blocks until a key produces a character, and returns it in
; AL. All the scan code interpreting stays on this side of the
; boundary, because it is driver work.
; ============================================================

kernel_getkey:

    push ebx


.next:

    cli


    movzx ebx, byte [kbd_tail]

    mov al, [kbd_head]

    cmp bl, al

    jne .have


    sti

    hlt

    jmp .next


.have:

    mov al, [kbd_queue + ebx]

    inc bl

    and bl, KBD_QUEUE_SIZE - 1

    mov [kbd_tail], bl

    sti


    test al, 80h

    jnz .release


    cmp al, 2Ah

    je .shift_on

    cmp al, 36h

    je .shift_on

    cmp al, 3Ah

    je .caps

    cmp al, 39h

    ja .next


    movzx ebx, al

    cmp byte [shift_state], 0

    je .normal

    mov al, [keymap_shift + ebx]

    jmp .mapped


.normal:

    mov al, [keymap + ebx]


.mapped:

    test al, al

    jz .next


    cmp byte [caps_state], 0

    je .done

    cmp al, 'a'

    jb .upper_check

    cmp al, 'z'

    ja .done

    cmp byte [shift_state], 0

    jne .done

    sub al, 32

    jmp .done


.upper_check:

    cmp al, 'A'

    jb .done

    cmp al, 'Z'

    ja .done

    cmp byte [shift_state], 0

    je .done

    add al, 32


.done:

    movzx eax, al

    pop ebx

    ret


.release:

    and al, 7Fh

    cmp al, 2Ah

    je .shift_off

    cmp al, 36h

    jne .next


.shift_off:

    mov byte [shift_state], 0

    jmp .next


.shift_on:

    mov byte [shift_state], 1

    jmp .next


.caps:

    xor byte [caps_state], 1

    jmp .next


; ============================================================
; REMAP THE INTERRUPT CONTROLLER
; ============================================================
;
; THIS IS NOT OPTIONAL.
;
; BIOS leaves IRQ0-7 mapped to interrupt vectors 8-15. In real
; mode that was harmless. In protected mode vectors 0-31 are
; reserved by the CPU for exceptions, and vector 8 is DOUBLE
; FAULT. Leave the mapping alone and the first timer tick
; looks like a fatal exception.
; ============================================================

pic_remap:

    push eax


    mov al, 11h                 ; ICW1: begin init, ICW4 follows

    out PIC1_CMD, al

    out PIC2_CMD, al


    mov al, IRQ_BASE            ; ICW2: new vector bases

    out PIC1_DATA, al

    mov al, IRQ_BASE + 8

    out PIC2_DATA, al


    mov al, 4                   ; ICW3: slave is on IRQ2

    out PIC1_DATA, al

    mov al, 2

    out PIC2_DATA, al


    mov al, 1                   ; ICW4: 8086 mode

    out PIC1_DATA, al

    out PIC2_DATA, al


    ; Unmask the timer (IRQ0) and the keyboard (IRQ1). The timer
    ; gives us a tick counter, which is all the splash needs and
    ; is also the thing a scheduler would eventually be built on.

    mov al, 11111100b

    out PIC1_DATA, al

    mov al, 11111111b

    out PIC2_DATA, al


    pop eax

    ret


%include "isr.asm"


; ============================================================
; SYSTEM CALL IMPLEMENTATIONS
; ============================================================

sys_putc:

    mov al, bl

    call vga_putc

    ret


sys_print:

    mov esi, ebx

    call vga_print

    ret


sys_getkey:

    call kernel_getkey

    ret


sys_clear:

    call vga_clear

    ret


sys_sysinfo:

    call cpu_info

    call mem_info

    call disk_info

    call kb_info

    call other_info

    ret


sys_reboot:

    cli

    mov al, 0FEh

    out KBD_CMD, al


.hang:

    hlt

    jmp .hang


; ============================================================
; FILE SYSTEM CALL SHIMS
; ============================================================

;
; The bodies live in fs.c now. INT 80h arrives with arguments
; in registers; cdecl wants them on the stack, pushed right to
; left, with the caller cleaning up.
;
; These few instructions are the whole translation.
; ============================================================

extern fs_stat

extern fs_read

extern fs_write

extern fs_delete

extern fs_format


; EBX = index, ECX = 16 byte destination

sys_file_stat:

    push ecx

    push ebx

    call fs_stat

    add esp, 8

    ret


; EBX = name, ECX = name length, EDX = destination

sys_file_read:

    push edx

    push ecx

    push ebx

    call fs_read

    add esp, 12

    ret


; EBX = name, ECX = name length, EDX = data, ESI = data length

sys_file_write:

    push esi

    push edx

    push ecx

    push ebx

    call fs_write

    add esp, 16

    ret


; EBX = name, ECX = name length

sys_file_delete:

    push ecx

    push ebx

    call fs_delete

    add esp, 8

    ret


sys_format:

    call fs_format

    ret


; ============================================================
; SYSTEM CALL TABLE
; ============================================================
;
; Indexed by the number INT 80h arrived with in EAX. The order
; here is the ABI: shell.c has matching #defines and the two
; must never drift apart.
; ============================================================

sys_table:

    dd sys_putc                 ; 0
    dd sys_print                ; 1
    dd sys_getkey               ; 2
    dd sys_clear                ; 3
    dd sys_sysinfo              ; 4
    dd sys_reboot               ; 5
    dd sys_file_stat            ; 6
    dd sys_file_read            ; 7
    dd sys_file_write           ; 8
    dd sys_file_delete          ; 9
    dd sys_format               ; 10

SYS_COUNT equ 11



; ============================================================
; DISK ACCESS FOR C
; ============================================================
;
; ata_read and ata_write take their arguments in registers and
; report failure in the carry flag. C wants stack arguments and
; an int result, so these translate.
;
;   int disk_read (unsigned lba, unsigned count, void *dst);
;   int disk_write(unsigned lba, unsigned count, const void *src);
;
; Both return 0 on success, -1 on failure.
; ============================================================

; ============================================================
; ENABLE PAGING
; ============================================================
;
; CR3 holds the physical address of the page directory. Setting
; bit 31 of CR0 turns translation on.
;
; C has no syntax for a control register, so this stays here.
;
;   void paging_enable(unsigned int page_dir_physical);
;
; The jump afterwards is not strictly required on a 386, but it
; makes the point that the very next instruction is already
; being fetched through the MMU. The mapping is identity, so
; EIP means the same thing on both sides of the switch -- which
; is exactly why an identity map is how you turn paging on.
; ============================================================

global paging_enable

paging_enable:

    push ebp

    mov ebp, esp


    mov eax, [ebp + 8]

    mov cr3, eax                ; where the directory lives


    mov eax, cr0

    or eax, 80000000h           ; PG - paging enable

    mov cr0, eax


    jmp short .flush


.flush:

    pop ebp

    ret


global disk_read

disk_read:

    push ebp

    mov ebp, esp

    push edi


    mov eax, [ebp + 8]          ; lba

    mov ecx, [ebp + 12]         ; sector count

    mov edi, [ebp + 16]         ; destination

    call ata_read


    mov eax, 0                  ; MOV does not disturb the carry flag

    jnc .done

    mov eax, -1


.done:

    pop edi

    pop ebp

    ret


global disk_write

disk_write:

    push ebp

    mov ebp, esp

    push esi


    mov eax, [ebp + 8]

    mov ecx, [ebp + 12]

    mov esi, [ebp + 16]

    call ata_write


    mov eax, 0

    jnc .done

    mov eax, -1


.done:

    pop esi

    pop ebp

    ret


; ============================================================
; TIMER INTERRUPT HANDLER
; ============================================================
;
; The PIT is left at the rate BIOS set it to, 18.2 ticks per
; second, which is plenty for timing a splash screen.
; ============================================================

isr_timer:

    pushad


    inc dword [ticks]


    mov al, PIC_EOI

    out PIC1_CMD, al


    popad

    iretd


; ============================================================
; SPLASH SCREEN
; ============================================================
;
; Printed by the kernel rather than the bootloader. The
; bootloader has about 200 bytes of room left and no video
; driver at all, so there is nowhere to put this; the kernel
; has both.
; ============================================================
;
; ESI = art string. '#' is drawn as the solid block character,
; so the source stays readable as ASCII art.

print_art:

    push eax

    push esi


.loop:

    lodsb

    test al, al

    jz .done

    cmp al, '#'

    jne .plain

    mov al, 0DBh                ; CP437 full block


.plain:

    call vga_putc

    jmp .loop


.done:

    pop esi

    pop eax

    ret


; Wait roughly EAX ticks, or until a key is pressed.

splash_wait:

    push ebx


    add eax, [ticks]

    mov ebx, eax                ; deadline


.spin:

    hlt                         ; woken by the timer or the keyboard


    mov al, [kbd_head]

    cmp al, [kbd_tail]

    jne .skipped                ; a key was pressed


    mov eax, [ticks]

    cmp eax, ebx

    jb .spin


    pop ebx

    ret


.skipped:

    ; Throw the key away so it does not turn up at the prompt.

    mov al, [kbd_head]

    mov [kbd_tail], al


    pop ebx

    ret


splash:

    call vga_clear


    mov byte [attr], 0Bh        ; light cyan

    mov esi, art

    call print_art


    mov byte [attr], 0Fh        ; bright white

    mov esi, splash_name

    call vga_print


    mov byte [attr], 07h

    mov esi, splash_sub

    call vga_print


    mov byte [attr], 08h        ; dark grey

    mov esi, splash_hint

    call vga_print


    mov byte [attr], 07h


    mov eax, 45                 ; about two and a half seconds

    call splash_wait


    call vga_clear

    ret


; ============================================================
; VGA TEXT DRIVER
; ============================================================
;
; Video memory is a plain array at 0xB8000 of 80 x 25 cells,
; two bytes each: character then attribute.
;
; cursor holds a cell index from 0 to 1999, not a byte offset.
; ============================================================

vga_clear:

    pushad


    mov edi, VGA_MEM

    mov ecx, VGA_COLS * VGA_ROWS

    mov ah, [attr]

    mov al, ' '

    rep stosw


    mov dword [cursor], 0

    call vga_move_cursor


    popad

    ret


vga_putc:

    pushad


    mov bl, al


    cmp bl, 13

    je .cr

    cmp bl, 10

    je .lf

    cmp bl, 8

    je .bs


    mov edi, [cursor]

    shl edi, 1

    add edi, VGA_MEM

    mov al, bl

    mov ah, [attr]

    mov [edi], ax

    inc dword [cursor]

    jmp .check


.cr:

    mov eax, [cursor]

    xor edx, edx

    mov ecx, VGA_COLS

    div ecx                     ; eax = row, edx = column

    mul ecx                     ; eax = row * 80

    mov [cursor], eax

    jmp .check


.lf:

    add dword [cursor], VGA_COLS

    jmp .check


.bs:

    cmp dword [cursor], 0

    je .check

    dec dword [cursor]

    mov edi, [cursor]

    shl edi, 1

    add edi, VGA_MEM

    mov al, ' '

    mov ah, [attr]

    mov [edi], ax


.check:

    ; A loop, not a single test: a line feed can push the
    ; cursor a whole row beyond the end at once.

    cmp dword [cursor], VGA_COLS * VGA_ROWS

    jb .done

    call vga_scroll

    sub dword [cursor], VGA_COLS

    jmp .check


.done:

    call vga_move_cursor

    popad

    ret


vga_scroll:

    pushad


    mov esi, VGA_MEM + VGA_COLS * 2

    mov edi, VGA_MEM

    mov ecx, VGA_COLS * (VGA_ROWS - 1)

    rep movsw


    mov edi, VGA_MEM + VGA_COLS * (VGA_ROWS - 1) * 2

    mov ecx, VGA_COLS

    mov ah, [attr]

    mov al, ' '

    rep stosw


    popad

    ret


; Register 14 holds the high byte of the cell index and
; register 15 the low byte.

vga_move_cursor:

    pushad


    mov ebx, [cursor]


    mov dx, CRTC_IDX

    mov al, 14

    out dx, al

    mov dx, CRTC_DAT

    mov al, bh

    out dx, al


    mov dx, CRTC_IDX

    mov al, 15

    out dx, al

    mov dx, CRTC_DAT

    mov al, bl

    out dx, al


    popad

    ret


; ============================================================
; C CALLING BRIDGE
; ============================================================
;
; The assembly routines take their arguments in registers. C
; uses cdecl: arguments pushed on the stack, caller cleans up,
; result in EAX.
;
; Anything C needs to call gets a small wrapper like this one.
;
;   void kputs(const char *s);
; ============================================================

global kputs

kputs:

    push ebp

    mov ebp, esp

    push esi


    mov esi, [ebp + 8]          ; first argument

    call vga_print


    pop esi

    pop ebp

    ret


; ESI = zero terminated string

vga_print:

    push eax

    push esi


.loop:

    lodsb

    test al, al

    jz .done

    call vga_putc

    jmp .loop


.done:

    pop esi

    pop eax

    ret


; ESI = first character, ECX = how many
;
; The line buffer is not zero terminated, so it needs this.

print_counted:

    pushad


.loop:

    jecxz .done

    lodsb

    call vga_putc

    dec ecx

    jmp .loop


.done:

    popad

    ret


; ============================================================
; NUMBER FORMATTING
; ============================================================
;
; EAX = value. Digits come out of the division in reverse, so
; they go on the stack and come back off in order.
; ============================================================

print_dec:

    pushad


    mov ebx, 10

    xor ecx, ecx


.divide:

    xor edx, edx

    div ebx

    push edx

    inc ecx

    test eax, eax

    jnz .divide


.emit:

    pop eax

    add al, '0'

    call vga_putc

    loop .emit


    popad

    ret


print_hex8:

    pushad


    mov bl, al

    shr al, 4

    call .digit

    mov al, bl

    call .digit


    popad

    ret


.digit:

    and al, 0Fh

    cmp al, 9

    jbe .num

    add al, 7                   ; 'A' - '0' - 10


.num:

    add al, '0'

    call vga_putc

    ret


print_hex16:

    pushad


    mov bx, ax

    mov al, bh

    call print_hex8

    mov al, bl

    call print_hex8


    popad

    ret


; ============================================================
; CPUID
; ============================================================
;
; CPUID exists only if bit 21 of EFLAGS can be flipped.
; Carry set = usable.
; ============================================================

has_cpuid:

    push eax

    push ecx


    pushfd

    pop eax

    mov ecx, eax

    xor eax, 200000h

    push eax

    popfd


    pushfd

    pop eax


    push ecx                    ; put the flags back
    popfd


    xor eax, ecx

    and eax, 200000h

    jz .no


    pop ecx

    pop eax

    stc

    ret


.no:

    pop ecx

    pop eax

    clc

    ret


cpu_info:

    mov esi, msg_si_cpu

    call vga_print


    call has_cpuid

    jnc .none


    xor eax, eax

    cpuid

    mov [CPU_BUF], ebx          ; vendor comes back as EBX:EDX:ECX

    mov [CPU_BUF + 4], edx

    mov [CPU_BUF + 8], ecx

    mov byte [CPU_BUF + 12], 0


    mov eax, 80000000h

    cpuid

    cmp eax, 80000004h

    jb .no_brand


    mov eax, 80000002h

    cpuid

    mov [CPU_BUF + 16], eax

    mov [CPU_BUF + 20], ebx

    mov [CPU_BUF + 24], ecx

    mov [CPU_BUF + 28], edx


    mov eax, 80000003h

    cpuid

    mov [CPU_BUF + 32], eax

    mov [CPU_BUF + 36], ebx

    mov [CPU_BUF + 40], ecx

    mov [CPU_BUF + 44], edx


    mov eax, 80000004h

    cpuid

    mov [CPU_BUF + 48], eax

    mov [CPU_BUF + 52], ebx

    mov [CPU_BUF + 56], ecx

    mov [CPU_BUF + 60], edx


    mov byte [CPU_BUF + 64], 0


    mov esi, CPU_BUF + 16

    call vga_print

    mov esi, msg_crlf

    call vga_print

    mov esi, msg_si_pad

    call vga_print


.no_brand:

    mov esi, CPU_BUF

    call vga_print


    mov eax, 1

    cpuid

    mov [cpu_sig], eax


    mov esi, msg_si_family

    call vga_print

    mov eax, [cpu_sig]

    shr eax, 8

    and eax, 0Fh

    call print_dec


    mov esi, msg_si_model

    call vga_print

    mov eax, [cpu_sig]

    shr eax, 4

    and eax, 0Fh

    call print_dec


    mov esi, msg_si_stepping

    call vga_print

    mov eax, [cpu_sig]

    and eax, 0Fh

    call print_dec


    mov esi, msg_crlf

    call vga_print

    ret


.none:

    mov esi, msg_si_nocpuid

    call vga_print

    ret


; ============================================================
; MEMORY, DISK AND EQUIPMENT
; ============================================================
;
; All from the survey taken before the switch, because these
; answers only exist while BIOS does.
; ============================================================

mem_info:

    mov esi, msg_si_mem

    call vga_print

    movzx eax, word [mem_conv]

    call print_dec

    mov esi, msg_si_kbconv

    call vga_print


    mov esi, msg_si_pad

    call vga_print

    call ext_kb_total

    call print_dec

    mov esi, msg_si_kbext

    call vga_print


    mov esi, msg_si_pad

    call vga_print

    call ext_kb_total

    movzx ebx, word [mem_conv]

    add eax, ebx

    call print_dec

    mov esi, msg_si_kbtotal

    call vga_print

    ret


; EAX = extended memory in KB

ext_kb_total:

    push ebx

    movzx eax, word [ext_kb]

    movzx ebx, word [ext_blocks]

    shl ebx, 6                  ; 64 KB blocks -> KB

    add eax, ebx

    pop ebx

    ret


disk_info:

    mov esi, msg_si_disk

    call vga_print

    movzx eax, byte [boot_drive]

    call print_hex8

    mov esi, msg_si_drivetail

    call vga_print


    cmp byte [edd_ok], 0

    je .none


    mov esi, msg_si_pad

    call vga_print

    mov eax, [edd_buf + 16]     ; total sectors, low 32 bits

    call print_dec

    mov esi, msg_si_sectors

    call vga_print

    movzx eax, word [edd_buf + 24]

    call print_dec

    mov esi, msg_si_bps

    call vga_print


    mov esi, msg_si_pad

    call vga_print

    mov esi, msg_si_chs

    call vga_print

    mov eax, [edd_buf + 4]

    call print_dec

    mov esi, msg_si_slash

    call vga_print

    mov eax, [edd_buf + 8]

    call print_dec

    mov esi, msg_si_slash

    call vga_print

    mov eax, [edd_buf + 12]

    call print_dec

    mov esi, msg_crlf

    call vga_print

    ret


.none:

    mov esi, msg_si_pad

    call vga_print

    mov esi, msg_si_noedd

    call vga_print

    ret


other_info:

    mov esi, msg_si_video

    call vga_print


    mov esi, msg_si_bios

    call vga_print

    mov ax, [equip]

    call print_hex16

    mov esi, msg_crlf

    call vga_print


    mov esi, msg_si_pad

    call vga_print


    movzx eax, word [equip]     ; bits 9-11 = serial ports

    shr eax, 9

    and eax, 7

    call print_dec

    mov esi, msg_si_serial

    call vga_print


    movzx eax, word [equip]     ; bits 14-15 = parallel ports

    shr eax, 14

    and eax, 3

    call print_dec

    mov esi, msg_si_parallel

    call vga_print

    ret


; ============================================================
; KEYBOARD IDENTIFY
; ============================================================
;
; Asks the keyboard itself (command F2h).
;
; IRQ1 has to be masked first, otherwise our own handler would
; read the reply out of port 0x60 before this code sees it.
; Every wait is bounded, so a keyboard that never answers
; costs a short pause rather than a hung machine.
; ============================================================

kb_wait_write:

    push ecx

    mov ecx, 0FFFFh


.spin:

    in al, KBD_CMD

    test al, 2

    jz .ready

    loop .spin

    pop ecx

    stc

    ret


.ready:

    pop ecx

    clc

    ret


kb_read:

    push ecx

    mov ecx, 0FFFFh


.spin:

    in al, KBD_CMD

    test al, 1

    jnz .ready

    loop .spin

    pop ecx

    stc

    ret


.ready:

    in al, KBD_DATA

    pop ecx

    clc

    ret


kb_drain:

    push ecx

    mov ecx, 32


.next:

    in al, KBD_CMD

    test al, 1

    jz .done

    in al, KBD_DATA

    loop .next


.done:

    pop ecx

    ret


kb_info:

    mov esi, msg_si_kbd

    call vga_print


    in al, PIC1_DATA

    mov [kb_saved_mask], al

    or al, 2

    out PIC1_DATA, al


    mov byte [kb_id0], 0

    mov byte [kb_id1], 0

    mov byte [kb_ack], 0


    call kb_wait_write

    jc .restore


    mov al, 0F2h                ; identify

    out KBD_DATA, al


    call kb_read

    jc .restore

    mov [kb_ack], al


    call kb_read

    jc .restore

    mov [kb_id0], al


    call kb_read

    jc .restore

    mov [kb_id1], al


.restore:

    call kb_drain

    mov al, [kb_saved_mask]

    out PIC1_DATA, al


    mov esi, msg_si_pad

    call vga_print

    mov esi, msg_si_kbid

    call vga_print

    mov al, [kb_ack]

    call print_hex8

    mov al, ' '

    call vga_putc

    mov al, [kb_id0]

    call print_hex8

    mov al, ' '

    call vga_putc

    mov al, [kb_id1]

    call print_hex8

    mov esi, msg_crlf

    call vga_print

    ret



; ============================================================
; ATA PIO DRIVER
; ============================================================
;
; This replaces INT 13h. BIOS is gone, so the disk is driven
; directly through its task file registers.
;
; LBA28 addressing, which is what the filesystem was written
; against from the start, so nothing above this layer changes.
; ============================================================

ata_wait_bsy:

    push eax

    push ecx

    push edx


    mov ecx, 100000h            ; bounded, so a dead drive cannot hang us

    mov dx, ATA_STATUS


.spin:

    in al, dx

    test al, ATA_BSY

    jz .ready

    loop .spin


    pop edx

    pop ecx

    pop eax

    stc

    ret


.ready:

    pop edx

    pop ecx

    pop eax

    clc

    ret


ata_wait_drq:

    push eax

    push ecx

    push edx


    mov ecx, 100000h

    mov dx, ATA_STATUS


.spin:

    in al, dx

    test al, ATA_ERR

    jnz .fail

    test al, ATA_BSY

    jnz .again

    test al, ATA_DRQ

    jnz .ready


.again:

    loop .spin


.fail:

    pop edx

    pop ecx

    pop eax

    stc

    ret


.ready:

    pop edx

    pop ecx

    pop eax

    clc

    ret


; ------------------------------------------------------------
; Load the task file registers.
;
; EAX = LBA, ECX = sector count
; ------------------------------------------------------------

ata_setup:

    pushad


    mov [ata_lba], eax

    mov [ata_cnt], ecx


    call ata_wait_bsy


    ; Drive select: master, LBA mode, plus LBA bits 24-27.

    mov eax, [ata_lba]

    shr eax, 24

    and al, 0Fh

    or al, 0E0h

    mov dx, ATA_DRIVE

    out dx, al


    xor al, al

    mov dx, ATA_FEAT

    out dx, al


    mov eax, [ata_cnt]

    mov dx, ATA_COUNT

    out dx, al


    mov eax, [ata_lba]

    mov dx, ATA_LBA0

    out dx, al


    mov eax, [ata_lba]

    shr eax, 8

    mov dx, ATA_LBA1

    out dx, al


    mov eax, [ata_lba]

    shr eax, 16

    mov dx, ATA_LBA2

    out dx, al


    popad

    ret


; ------------------------------------------------------------
; ata_read - EAX = LBA, ECX = sectors, EDI = destination
; ------------------------------------------------------------

ata_read:

    pushad


    call ata_setup


    mov dx, ATA_CMD

    mov al, 20h                 ; READ SECTORS

    out dx, al


    mov ecx, [ata_cnt]


.sector:

    call ata_wait_drq

    jc .fail


    push ecx

    mov ecx, 256                ; 256 words per 512 byte sector

    mov dx, ATA_DATA

    rep insw

    pop ecx


    loop .sector


    popad

    clc

    ret


.fail:

    popad

    stc

    ret


; ------------------------------------------------------------
; ata_write - EAX = LBA, ECX = sectors, ESI = source
; ------------------------------------------------------------

ata_write:

    pushad


    call ata_setup


    mov dx, ATA_CMD

    mov al, 30h                 ; WRITE SECTORS

    out dx, al


    mov ecx, [ata_cnt]


.sector:

    call ata_wait_drq

    jc .fail


    push ecx

    mov ecx, 256

    mov dx, ATA_DATA

    rep outsw

    pop ecx


    loop .sector


    ; The drive may be holding the data in its cache. Ask it to
    ; commit before we claim the file is saved.

    call ata_wait_bsy

    mov dx, ATA_CMD

    mov al, 0E7h                ; CACHE FLUSH

    out dx, al

    call ata_wait_bsy


    popad

    clc

    ret


.fail:

    popad

    stc

    ret


; ============================================================
; DATA
; ============================================================

boot_drive:

    db 0


attr:

    db 07h


cursor:

    dd 0


; Incremented by the timer, 18.2 times a second.

ticks:

    dd 0


; ---- keyboard state ----

kbd_queue:

    times KBD_QUEUE_SIZE db 0


kbd_head:

    db 0


kbd_tail:

    db 0


shift_state:

    db 0


caps_state:

    db 0


; ---- shell state ----

input_len:

    dd 0


name_len:

    dd 0


arg_ptr:

    dd 0


arg_len:

    dd 0


; ---- collected from BIOS before the switch ----

mem_conv:

    dw 0


ext_kb:

    dw 0


ext_blocks:

    dw 0


equip:

    dw 0


edd_ok:

    db 0


edd_buf:

    dw 26

    times 24 db 0


; ---- sysinfo scratch ----

cpu_sig:

    dd 0


kb_saved_mask:

    db 0


kb_ack:

    db 0


kb_id0:

    db 0


kb_id1:

    db 0


; ---- disk and editor state ----

ata_lba:

    dd 0


ata_cnt:

    dd 0


edit_mode:

    db 0


edit_len:

    dd 0


edit_lines:

    dd 0


edit_index:

    dd 0


; Scratch for sys_file_write, which needs its arguments after
; the helper routines have used the registers.

fs_data:

    dd 0


fs_len:

    dd 0


fs_index:

    dd 0


; ============================================================
; KEYBOARD SCAN CODE SET 1
; ============================================================

keymap:

    db 0,0

    db "1234567890-="

    db 8,9

    db "qwertyuiop[]"

    db 13,0

    db "asdfghjkl;'`"

    db 0

    db "\zxcvbnm,./"

    db 0

    db "*"

    db 0

    db " "


keymap_shift:

    db 0,0

    db "!@#$%^&*()_+"

    db 8,9

    db "QWERTYUIOP{}"

    db 13,0

    db 'ASDFGHJKL:"~'

    db 0

    db "|ZXCVBNM<>?"

    db 0

    db "*"

    db 0

    db " "


; ============================================================
; MESSAGES
; ============================================================

msg_banner:

    db 13,10
    db "==================",13,10
    db " ARICS OS V2.0",13,10
    db "==================",13,10
    db "32 bit protected mode. Type help for commands.",13,10,13,10,0


prompt_str:

    db "AOS> ",0


msg_crlf:

    db 13,10,0


msg_unknown:

    db "Unknown command: ",0


msg_fault:

    db 13,10,"*** unhandled interrupt - halted ***",13,10,0


msg_exc:

    db 13,10,"*** CPU exception ",0


msg_exc_tail:

    db " - halted ***",13,10,0


; ---- sysinfo text ----

msg_si_cpu:         db "CPU:      ",0
msg_si_pad:         db "          ",0
msg_si_nocpuid:     db "pre-486, no CPUID",13,10,0
msg_si_family:      db "  family ",0
msg_si_model:       db " model ",0
msg_si_stepping:    db " stepping ",0

msg_si_mem:         db "Memory:   ",0
msg_si_kbconv:      db " KB conventional",13,10,0
msg_si_kbext:       db " KB extended",13,10,0
msg_si_kbtotal:     db " KB total",13,10,0

msg_si_disk:        db "Disk:     boot drive ",0
msg_si_drivetail:   db "h",13,10,0
msg_si_sectors:     db " sectors of ",0
msg_si_bps:         db " bytes",13,10,0
msg_si_chs:         db "geometry C/H/S ",0
msg_si_slash:       db "/",0
msg_si_noedd:       db "no parameters available",13,10,0

msg_si_kbd:         db "Keyboard: PS/2 8042, IRQ1 on vector 21h",13,10,0
msg_si_kbid:        db "device ID ",0

msg_si_video:       db "Video:    80x25 text, direct writes to 0xB8000",13,10,0
msg_si_bios:        db "BIOS:     equipment word ",0
msg_si_serial:      db " serial, ",0
msg_si_parallel:    db " parallel",13,10,0


; ---- filesystem text ----

msg_gt:             db "> ",0
msg_gap:            db "  ",0
msg_bytes_nl:       db " bytes",13,10,0
msg_saved:          db "saved ",0
msg_diskerr:        db "disk error",13,10,0
msg_nofile:         db "no such file",13,10,0
msg_dirfull:        db "directory full",13,10,0
msg_full:           db "file full, line ignored",13,10,0
msg_removed:        db "removed",13,10,0
msg_formatted:      db "directory cleared",13,10,0
msg_editing:        db "Enter text. A single . on a line saves and exits.",13,10,0
msg_usage_read:     db "usage: read <name>",13,10,0
msg_usage_write:    db "usage: write <name>",13,10,0
msg_usage_rm:       db "usage: rm <name>",13,10,0

; ============================================================
; SPLASH TEXT
; ============================================================
;
; Five rows of block letters. '#' is swapped for the solid
; block glyph by print_art, so this stays legible in an editor.
; The art is 48 columns wide, indented 16 to centre it in 80.
; ============================================================

art:

    db 13,10,13,10,13,10
    db "                ####  #####  ####  #####  #####     ####   #####",13,10
    db "               ##  ## ##  ##  ##  ##     ##        ##  ## ##    ",13,10
    db "               ###### #####   ##  ##      ####     ##  ##  #### ",13,10
    db "               ##  ## ##  ##  ##  ##         ##    ##  ##     ##",13,10
    db "               ##  ## ##  ## ####  ##### #####      ####  ##### ",13,10
    db 0


splash_name:

    db 13,10
    db "                          A R I C S   O S",13,10,0


splash_sub:

    db 13,10
    db "            32 bit protected mode, written from scratch",13,10
    db "               Ring 0 kernel  -  Ring 3 shell  -  no BIOS",13,10,0


splash_hint:

    db 13,10,13,10
    db "                        Press any key to continue",13,10,0


; The shell is now shell.c, compiled separately and linked in.
; entry.asm needs its address for the ring 3 IRET frame.

extern shell_main
