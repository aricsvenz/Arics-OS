; ============================================================
; INTERRUPT PLUMBING  -  ALSO NEVER C
; ============================================================
;
; Included by kernel.asm.
;
; Interrupt handlers cannot be plain C functions. The CPU
; pushes its own frame and the handler must finish with IRETD,
; not RET. A C kernel still writes these stubs in assembly and
; has them call C functions to do the actual work, which is
; exactly the shape this file will take later.
; ============================================================


; ============================================================
; INTERRUPT DESCRIPTOR TABLE
; ============================================================
;
;   +0  handler offset, low 16 bits
;   +2  code selector
;   +4  always zero
;   +5  type and attributes (8Eh = present, ring 0, 32 bit
;                            interrupt gate)
;   +6  handler offset, high 16 bits
;
; idt_set: EAX = handler, ECX = vector, DL = gate type
;
;   8Eh = present, DPL 0, 32 bit interrupt gate
;   EFh = present, DPL 3, 32 bit trap gate
;
; The syscall gate must be DPL 3 or ring 3 could not invoke it,
; and a trap gate rather than an interrupt gate so that IF is
; left alone -- a blocking read needs interrupts to stay on.
; ============================================================

idt_set:

    push edi


    mov edi, ecx

    shl edi, 3

    add edi, IDT_BASE


    mov [edi], ax

    mov word [edi + 2], CODE_SEG

    mov byte [edi + 4], 0

    mov [edi + 5], dl


    ror eax, 16

    mov [edi + 6], ax

    rol eax, 16


    pop edi

    ret


idt_init:

    pushad


    mov dl, 8Eh

    xor ecx, ecx


.fill:

    mov eax, isr_default

    call idt_set

    inc ecx

    cmp ecx, IDT_ENTRIES

    jb .fill


    ; ---- CPU exceptions 0 to 31 ----

    xor ecx, ecx


.exc:

    mov eax, [exc_table + ecx * 4]

    mov dl, 8Eh

    call idt_set

    inc ecx

    cmp ecx, 32

    jb .exc


    ; ---- timer ----

    mov eax, isr_timer

    mov ecx, IRQ_BASE

    mov dl, 8Eh

    call idt_set


    ; ---- keyboard ----

    mov eax, isr_keyboard

    mov ecx, IRQ_BASE + 1

    mov dl, 8Eh

    call idt_set


    ; ---- system call gate, reachable from ring 3 ----

    mov eax, isr_syscall

    mov ecx, 80h

    mov dl, 0EFh

    call idt_set


    lidt [idt_descriptor]


    popad

    ret


idt_descriptor:

    dw IDT_ENTRIES * 8 - 1

    dd IDT_BASE


; ============================================================
; DEFAULT INTERRUPT HANDLER
; ============================================================
;
; Halts with a message. Returning instead would re-run the
; faulting instruction forever and look like a hung machine.
; ============================================================

isr_default:

    cli

    mov esi, msg_fault

    call vga_print


.hang:

    hlt

    jmp .hang


; ============================================================
; KEYBOARD INTERRUPT HANDLER
; ============================================================
;
; IRETD, not IRET: in 32 bit mode the CPU pushed a 32 bit
; return frame.
; ============================================================

isr_keyboard:

    pushad


    in al, KBD_DATA


    movzx ebx, byte [kbd_head]

    mov [kbd_queue + ebx], al

    inc bl

    and bl, KBD_QUEUE_SIZE - 1

    cmp bl, [kbd_tail]

    je .full

    mov [kbd_head], bl


.full:

    mov al, PIC_EOI

    out PIC1_CMD, al


    popad

    iretd



; ============================================================
; CPU EXCEPTION HANDLERS
; ============================================================
;
; One tiny stub per vector so the handler knows which one
; fired. Generated rather than written out 32 times.
; ============================================================

%assign exc_i 0
%rep 32
isr_exc_ %+ exc_i:
    push dword exc_i
    jmp exception_common
%assign exc_i exc_i+1
%endrep


exc_table:

%assign exc_i 0
%rep 32
    dd isr_exc_ %+ exc_i
%assign exc_i exc_i+1
%endrep


; ------------------------------------------------------------
; Report and stop.
;
; This is what a ring 3 program hits when it tries something
; only the kernel is allowed to do.
; ------------------------------------------------------------

exception_common:

    cli

    mov ax, DATA_SEG

    mov ds, ax

    mov es, ax


    mov esi, msg_exc

    call vga_print

    pop eax

    call print_dec

    mov esi, msg_exc_tail

    call vga_print


.hang:

    hlt

    jmp .hang


; ============================================================
; SYSTEM CALL ENTRY
; ============================================================
;
; The only door from ring 3 into the kernel.
;
;   EAX = call number, returned value comes back in EAX
;   EBX, ECX, EDX, ESI = arguments
;
; DS and ES still hold the caller's ring 3 selectors on entry,
; so they are swapped for kernel ones before touching anything.
; ============================================================

isr_syscall:

    push ebx

    push ecx

    push edx

    push esi

    push edi

    push ebp

    push ds

    push es


    push eax

    mov ax, DATA_SEG

    mov ds, ax

    mov es, ax

    pop eax


    cmp eax, SYS_COUNT

    jnb .bad


    call [sys_table + eax * 4]

    jmp .done


.bad:

    xor eax, eax


.done:

    pop es

    pop ds

    pop ebp

    pop edi

    pop esi

    pop edx

    pop ecx

    pop ebx

    iretd
