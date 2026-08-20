; ============================================================
; BOOTLOADER  -  STAGE 1
; AUTHOR - AMOL SINGH (https://amolsingh.in) | aricsvenz@gmail.com
; ============================================================
;
; BIOS loads this code at 0000:7C00.
;
; Job:
;
;   1. Load the kernel from disk
;   2. Ask BIOS everything the kernel will want to know later
;   3. Enable the A20 line
;   4. Enter 32 bit protected mode
;   5. Jump to the kernel, already in 32 bit mode
;
; WHY THE MODE SWITCH LIVES HERE
;
; 16 bit code cannot be a linkable object file: an instruction
; like "mov si, message" needs a 16 bit relocation, and COFF
; has no way to express one. So the moment the kernel wanted to
; be linked from object files and mixed with C, every last 16
; bit instruction had to leave it.
;
; That turns out to be the right division anyway. A bootloader's
; job is to reach a sane 32 bit environment and hand over; this
; is exactly what GRUB would do for us.
;
; The kernel is entered at 0x8000 already in protected mode and
; is 100% 32 bit code.
; ============================================================

bits 16
org 0x7C00


KERNEL_LOAD_SEG  equ 0x0000

KERNEL_LOAD_OFF  equ 0x8000


; Kernel size = 32 sectors
; 32 x 512 = 16384 bytes
;
; Sectors 2..33 of track 0. A track holds 63 sectors, so this
; stays inside one track and needs no head or cylinder change.

KERNEL_SECTORS   equ 32


; ============================================================
; BOOT INFORMATION BLOCK
; ============================================================
;
; BIOS can only be asked things while we are still in real
; mode. The answers are written to a fixed address in low
; memory and the kernel picks them up from there.
;
; This is the entire interface between bootloader and kernel,
; besides the entry address itself.
;
;   +0   word   conventional memory, KB
;   +2   word   extended memory, KB below 16 MB
;   +4   word   extended memory, 64 KB blocks above that
;   +6   word   BIOS equipment word
;   +8   byte   boot drive number
;   +9   byte   1 if the disk parameters below are valid
;   +10  26     INT 13h AH=48h result buffer
; ============================================================

BOOTINFO    equ 0x7000

BI_CONV     equ BOOTINFO + 0

BI_EXT_KB   equ BOOTINFO + 2

BI_EXT_BLK  equ BOOTINFO + 4

BI_EQUIP    equ BOOTINFO + 6

BI_DRIVE    equ BOOTINFO + 8

BI_EDD_OK   equ BOOTINFO + 9

BI_EDD      equ BOOTINFO + 10


; ============================================================
; GDT SELECTORS
; ============================================================

CODE_SEG equ gdt_code - gdt_start

DATA_SEG equ gdt_data - gdt_start


start:

    cli


    xor ax, ax

    mov ds, ax

    mov es, ax

    mov ss, ax

    mov sp, 0x7C00

    cld


    ; BIOS leaves the drive we booted from in DL.

    mov [BI_DRIVE], dl


    ; --------------------------------------------------------
    ; Load the kernel using BIOS INT 13h
    ;
    ; AH = 02h  -> read sectors
    ; AL = number of sectors
    ; CH = cylinder      CL = starting sector
    ; DH = head          DL = drive
    ; ES:BX = destination
    ;
    ; Sector 1 = this bootloader, sector 2 onward = kernel.
    ; --------------------------------------------------------

    mov ah, 02h

    mov al, KERNEL_SECTORS

    mov ch, 00h

    mov cl, 02h

    mov dh, 00h

    mov dl, [BI_DRIVE]

    mov bx, KERNEL_LOAD_OFF

    int 13h

    jc disk_error


    call bios_survey

    call enable_a20


    ; --------------------------------------------------------
    ; Into protected mode.
    ;
    ; Setting bit 0 of CR0 switches the CPU immediately, but CS
    ; still holds a real mode segment value until a far jump
    ; reloads it from the GDT. The jump also flushes the
    ; pipeline, which may hold instructions already decoded as
    ; 16 bit.
    ; --------------------------------------------------------

    lgdt [gdt_descriptor]


    mov eax, cr0

    or eax, 1

    mov cr0, eax


    jmp CODE_SEG:protected_entry


; ============================================================
; ASK BIOS WHILE IT STILL EXISTS
; ============================================================
;
; Memory size, disk geometry and the equipment word can only be
; obtained through BIOS calls. After the switch there is no way
; to ask, so the answers are collected now.
; ============================================================

bios_survey:

    ; ---- conventional memory, in KB ----

    int 12h

    mov [BI_CONV], ax


    ; ---- extended memory ----
    ;
    ; AX = KB up to 16 MB, BX = 64 KB blocks above that.
    ; Some BIOSes answer in CX/DX instead.

    xor ax, ax

    mov [BI_EXT_KB], ax

    mov [BI_EXT_BLK], ax


    mov ax, 0E801h

    int 15h

    jc .no_ext

    test ax, ax

    jnz .have_ext

    mov ax, cx

    mov bx, dx


.have_ext:

    mov [BI_EXT_KB], ax

    mov [BI_EXT_BLK], bx


.no_ext:

    ; ---- equipment word ----

    int 11h

    mov [BI_EQUIP], ax


    ; ---- disk parameters ----

    mov byte [BI_EDD_OK], 0

    mov word [BI_EDD], 26       ; tell the BIOS our buffer size

    mov ah, 48h

    mov dl, [BI_DRIVE]

    mov si, BI_EDD

    int 13h

    jc .no_disk

    mov byte [BI_EDD_OK], 1


.no_disk:

    ret


; ============================================================
; ENABLE A20
; ============================================================
;
; On the original PC, address line 20 was held low, so any
; address above 1 MB wrapped around to 0. That behaviour was
; kept for compatibility and has to be switched off before
; memory above 1 MB is reachable.
;
; Bit 0 of port 0x92 triggers a system reset, so it must be
; masked off carefully.
; ============================================================

enable_a20:

    mov ax, 2401h

    int 15h


    in al, 0x92

    test al, 2

    jnz .done

    or al, 2

    and al, 0FEh

    out 0x92, al


.done:

    ret


; ============================================================
; DISK ERROR
; ============================================================

disk_error:

    mov si, error_message

    call print_string


hang:

    cli

    hlt

    jmp hang


print_string:

    lodsb

    test al, al

    jz .done

    mov ah, 0Eh

    mov bh, 0

    int 10h

    jmp print_string


.done:

    ret


; ============================================================
; BOOT GDT
; ============================================================
;
; Just enough to get into 32 bit mode: a null descriptor, a
; flat code segment and a flat data segment.
;
; The kernel installs its own richer GDT once it is running,
; with ring 3 descriptors and a TSS. This one only has to
; survive the far jump.
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


gdt_end:


gdt_descriptor:

    dw gdt_end - gdt_start - 1

    dd gdt_start


; ============================================================
; 32 BIT LANDING PAD
; ============================================================
;
; A handful of instructions to load the flat data selectors and
; jump to the kernel. This is the only 32 bit code in the
; bootloader, and it exists because the far jump above has to
; land somewhere before control can leave for 0x8000.
; ============================================================

bits 32

protected_entry:

    mov ax, DATA_SEG

    mov ds, ax

    mov es, ax

    mov fs, ax

    mov gs, ax

    mov ss, ax


    mov esp, 0x90000


    jmp KERNEL_LOAD_OFF


; ============================================================
; DATA
; ============================================================

error_message:

    db "Disk read error!", 13, 10, 0


; ============================================================
; MBR PARTITION TABLE
; ============================================================

times 446-($-$$) db 0


; Partition #1, bootable

db 80h

db 01h, 01h, 00h                ; starting CHS

db 06h                          ; type

db 0FEh, 0FFh, 0FFh             ; ending CHS

dd 1                            ; starting LBA

dd 00766498h                    ; sector count


; Partitions 2-4 unused

times 16*3 db 0


; ============================================================
; BIOS BOOT SIGNATURE
; ============================================================

dw 0AA55h
