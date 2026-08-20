/* ============================================================
 * KERNEL  -  C SIDE
 * ============================================================
 *
 * The first C in the project. Called from entry.asm once the
 * CPU is in 32 bit protected mode, the GDT and IDT are loaded
 * and the drivers are up.
 *
 * Compiled freestanding: no standard library, no runtime, no
 * operating system underneath. printf and malloc do not exist
 * here, and anything this file needs it either writes itself
 * or asks the assembly side for.
 *
 * Symbols are built with -fno-leading-underscore so the names
 * here match the ones NASM exports exactly.
 * ============================================================ */

/* Implemented in kernel.asm as a cdecl wrapper around the VGA
   driver. */
extern void kputs(const char *s);


void kmain(void)
{
    kputs("\r\nC is running in the kernel.\r\n");
}
