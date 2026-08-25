/* ============================================================
 * KERNEL  -  C SIDE
 * AUTHOR - AMOL SINGH (https://amolsingh.in) | aricsvenz@gmail.com
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


/* Added by Nayan - small deterministic delay used only for the visual boot
 * progress animation. volatile prevents the compiler from removing it. */
static void boot_delay(unsigned int amount)
{
    volatile unsigned int i;
    for (i = 0; i < amount; i++) {
        __asm__ __volatile__("nop");
    }
}


/* Added by Nayan - show a compact ARICS mark and a visible progress bar
 * after the protected-mode splash and before the ring-3 shell starts. */
static void boot_loading_screen(void)
{
    kputs("\r\n"
          "                 /\\        R I C S\r\n"
          "                /  \\       O S\r\n"
          "               / /\\ \\\r\n"
          "              / ____ \\\r\n"
          "             /_/    \\_\\\r\n"
          "\r\n"
          "                    ARICS OS\r\n"
          "             Secure 32-bit startup\r\n\r\n"
          "             Loading kernel  [");

    for (int i = 0; i < 24; i++) {
        kputs("#");
        boot_delay(1400000U);
    }

    kputs("]\r\n"
          "             Initializing shell... done\r\n"
          "             Starting ARICS OS...\r\n\r\n");

    boot_delay(2500000U);
}


void kmain(void)
{
    /* Added by Nayan - replace the old developer-only boot message with
     * a user-facing logo/loading sequence. */
    boot_loading_screen();
}
