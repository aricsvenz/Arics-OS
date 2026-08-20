/* ============================================================
 * PAGING
 * ============================================================
 *
 * Turns on the MMU. From the moment CR0.PG is set, every
 * address the CPU sees is virtual and gets translated through
 * two levels of tables before it reaches memory.
 *
 *   virtual address
 *     bits 31-22  index into the page directory
 *     bits 21-12  index into that directory entry's page table
 *     bits 11-0   offset within the 4 KB page
 *
 * The mapping installed here is an IDENTITY map of the first
 * 4 MB: virtual address X becomes physical address X. Nothing
 * moves, so the kernel, the drivers, the VGA buffer at
 * 0xB8000, both stacks and every fixed buffer keep working
 * exactly as they did.
 *
 * That sounds like it achieves nothing, and as a mapping it
 * almost doesn't. What it achieves is that translation is now
 * happening at all: anything OUTSIDE the mapped range no
 * longer exists as far as the CPU is concerned, and touching
 * it raises a page fault instead of quietly reading rubbish.
 *
 * Everything above 4 MB is deliberately left unmapped, which
 * is what the shell's "poke" command runs into.
 * ============================================================ */

#define PAGE_PRESENT   0x001       /* the page is actually there   */
#define PAGE_WRITE     0x002       /* writable, not just readable  */
#define PAGE_USER      0x004       /* ring 3 may touch it          */

#define ENTRIES        1024        /* per table, 1024 * 4 bytes = one page */
#define PAGE_SIZE      4096
#define MAPPED_BYTES   (ENTRIES * PAGE_SIZE)   /* 4 MB */


/* In kernel.asm: loads CR3 and sets the PG bit in CR0. Needs
   to be assembly because C has no way to name a control
   register. */
extern void paging_enable(unsigned int page_dir_physical);


/* Both tables must start on a 4 KB boundary: the CPU takes the
   low 12 bits of these addresses as flags, not as address
   bits. They live in .bss, which the linker page aligns and
   entry.asm zeroes, and which costs nothing in the image
   because a flat binary stores no .bss on disk. */
static unsigned int page_directory[ENTRIES] __attribute__((aligned(PAGE_SIZE)));
static unsigned int page_table_0[ENTRIES]   __attribute__((aligned(PAGE_SIZE)));


void paging_init(void)
{
    /* Identity map the first 4 MB.
     *
     * PAGE_USER is set on everything for now. Ring 3 can
     * already reach all of memory through the flat segments,
     * so this changes nothing yet -- tightening it is a
     * separate step, and doing both at once would make a
     * failure impossible to diagnose. */
    for (unsigned int i = 0; i < ENTRIES; i++)
        page_table_0[i] = (i * PAGE_SIZE) | PAGE_PRESENT | PAGE_WRITE | PAGE_USER;

    /* Directory entry 0 covers virtual 0 to 4 MB. */
    page_directory[0] = (unsigned int)page_table_0
                      | PAGE_PRESENT | PAGE_WRITE | PAGE_USER;

    /* Every other entry stays absent. A virtual address above
       4 MB has no page table to walk into, so the CPU raises
       exception 14 rather than inventing an answer. */
    for (unsigned int i = 1; i < ENTRIES; i++)
        page_directory[i] = 0;

    paging_enable((unsigned int)page_directory);
}


/* Reported by sysinfo. */
unsigned int paging_mapped_bytes(void)
{
    return MAPPED_BYTES;
}
