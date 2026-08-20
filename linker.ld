/* ============================================================
 * Linker script - replaces "org 0x8000"
 *
 * The bootloader jumps blindly to 0x8000, so whatever is at
 * that address had better be kernel_entry. That is why
 * kernel_asm.o is listed first: entry.asm is included at the
 * top of kernel.asm, so its first instruction leads the
 * output section.
 *
 * Everything is merged into one section. PE aligns sections to
 * 4 KB by default, and separate .text / .data / .rdata would
 * leave multi-kilobyte holes in a flat binary.
 * ============================================================ */

ENTRY(kernel_entry)

SECTIONS
{
    . = 0x8000;

    .text : {
        kernel_asm.o(.text)
        *(.text)
        *(.rdata*)
        *(.data)
    }

    /* C globals live here. A flat binary carries no .bss on
       disk, so the kernel must zero this range itself before
       any C code runs - see zero_bss in entry.asm. */
    /* The page directory and page tables must start on a 4 KB
       boundary, so the section itself has to be aligned before
       the compiler's aligned(4096) request can be honoured. */
    . = ALIGN(4096);

    .bss : {
        __bss_start = .;
        *(.bss)
        *(COMMON)
        __bss_end = .;
    }
}
