/* ============================================================
 * FILESYSTEM
 * ============================================================
 *
 * A format of our own, deliberately simple.
 *
 *   LBA 0        bootloader
 *   LBA 1-32     kernel
 *   LBA 33       directory, one sector
 *   LBA 34+      file data
 *
 * Entry N always owns the sectors starting at
 * DATA_LBA + N * FILE_SECTORS. Fixed slots mean there is no
 * free space allocator to get wrong. start_lba is still stored
 * in the entry, so the read path does not depend on that rule
 * and a real allocator can replace it later without touching
 * anything below.
 *
 * This runs in ring 0. Everything here is reached from the
 * INT 80h handler, never called directly by the shell.
 *
 * The disk itself stays in assembly: ata_read and ata_write
 * move a sector with a single REP INSW / REP OUTSW, which C
 * cannot express and would only make worse.
 * ============================================================ */

#define DIR_LBA        33
#define DATA_LBA       34
#define FILE_SECTORS    4          /* 2048 bytes per file */
#define MAX_FILES      16
#define NAME_MAX       11
#define SECTOR_SIZE   512

/* Added by Nayan - keep the physical file-slot size in one place.
 * Lengths supplied by ring 3 or loaded from disk must never exceed it. */
#define FILE_MAX      (FILE_SECTORS * SECTOR_SIZE)


/* cdecl wrappers around the ATA driver, in kernel.asm.
   Both return 0 on success and -1 on failure. */
extern int disk_read(unsigned int lba, unsigned int count, void *dst);
extern int disk_write(unsigned int lba, unsigned int count, const void *src);


/* ------------------------------------------------------------
 * Directory entry, 16 bytes on disk.
 *
 * packed because the layout is dictated by the format, not by
 * the compiler's alignment preferences.
 * ------------------------------------------------------------ */

struct dirent {
    unsigned char  flags;              /* 0 = free, 1 = used */
    char           name[NAME_MAX];     /* NUL padded          */
    unsigned short start_lba;
    unsigned short length;
} __attribute__((packed));


/* The directory is a whole sector, but only 16 entries of it
   are used. Reading into a bare array of entries would let the
   other 256 bytes run off the end. */
static union {
    struct dirent entry[MAX_FILES];
    unsigned char raw[SECTOR_SIZE];
} dir;


static int dir_load(void)  { return disk_read(DIR_LBA, 1, dir.raw); }
static int dir_save(void)  { return disk_write(DIR_LBA, 1, dir.raw); }


static void copy(void *dst, const void *src, int n)
{
    unsigned char       *d = dst;
    const unsigned char *s = src;

    for (int i = 0; i < n; i++)
        d[i] = s[i];
}


static int name_ok(int len)
{
    return len >= 1 && len <= NAME_MAX;
}


/* Added by Nayan - fixed-slot metadata should never be allowed to
 * redirect a file read to arbitrary LBAs if the directory is damaged. */
static unsigned int slot_lba(int index)
{
    return DATA_LBA + (unsigned int)index * FILE_SECTORS;
}


/* Both names must end at the same point, otherwise "a" would
   match "abc". */
static int name_matches(const struct dirent *e, const char *name, int len)
{
    for (int i = 0; i < len; i++)
        if (e->name[i] != name[i])
            return 0;

    if (len < NAME_MAX && e->name[len] != 0)
        return 0;

    return 1;
}


/* Both searches assume the directory is already loaded.
   They return an index, or -1. */

static int find_file(const char *name, int len)
{
    for (int i = 0; i < MAX_FILES; i++)
        if (dir.entry[i].flags && name_matches(&dir.entry[i], name, len))
            return i;

    return -1;
}


static int find_free(void)
{
    for (int i = 0; i < MAX_FILES; i++)
        if (!dir.entry[i].flags)
            return i;

    return -1;
}


/* ============================================================
 * SYSTEM CALL BODIES
 * ============================================================
 *
 * Called from the shims in kernel.asm, which unpack the
 * register arguments INT 80h arrived with into a cdecl call.
 * ============================================================ */

/* Copies one raw directory entry out to the caller.
   Returns 1 if the slot is used, 0 if free or invalid. */
int fs_stat(int index, void *dest)
{
    /* Added by Nayan - reject an obviously invalid destination pointer. */
    if (index < 0 || index >= MAX_FILES || dest == 0)
        return 0;

    if (dir_load() < 0)
        return 0;

    copy(dest, &dir.entry[index], sizeof(struct dirent));

    return dir.entry[index].flags;
}


/* Returns the file length, or -1.
   dest must have room for FILE_SECTORS * SECTOR_SIZE bytes. */
int fs_read(const char *name, int len, void *dest)
{
    /* Added by Nayan - syscall pointers and lengths are untrusted input. */
    if (name == 0 || dest == 0 || !name_ok(len) || dir_load() < 0)
        return -1;

    int i = find_file(name, len);

    if (i < 0)
        return -1;

    /* Added by Nayan - reject corrupt metadata before disk I/O or before
     * returning a length that could make userspace overrun its buffer. */
    if (dir.entry[i].length > FILE_MAX)
        return -1;

    if ((unsigned int)dir.entry[i].start_lba != slot_lba(i))
        return -1;

    if (disk_read(dir.entry[i].start_lba, FILE_SECTORS, dest) < 0)
        return -1;

    return dir.entry[i].length;
}


/* Creates the file, or overwrites it if the name already
   exists. Returns 0 or -1. */
int fs_write(const char *name, int len, const void *data, int datalen)
{
    /* Added by Nayan - ring 3 controls every argument to this syscall.
     * Never store a length larger than the physical 2 KB file slot. */
    if (name == 0 || data == 0 || !name_ok(len))
        return -1;

    if (datalen < 0 || datalen > FILE_MAX)
        return -1;

    if (dir_load() < 0)
        return -1;

    int i = find_file(name, len);

    if (i < 0)
        i = find_free();

    if (i < 0)
        return -1;

    struct dirent *e = &dir.entry[i];

    for (int k = 0; k < NAME_MAX; k++)
        e->name[k] = (k < len) ? name[k] : 0;

    /* Fixed slot: this entry always owns the same sectors. */
    e->start_lba = (unsigned short)slot_lba(i);

    /* Data first, then the directory entry that points at it. */
    if (disk_write(e->start_lba, FILE_SECTORS, data) < 0)
        return -1;

    e->length = (unsigned short)datalen;
    e->flags  = 1;

    return dir_save();
}


int fs_delete(const char *name, int len)
{
    if (name == 0 || !name_ok(len) || dir_load() < 0)
        return -1;

    int i = find_file(name, len);

    if (i < 0)
        return -1;

    /* Added by Nayan - clear the complete entry rather than leaving stale
     * filename, sector and length metadata behind in a free slot. */
    unsigned char *p = (unsigned char *)&dir.entry[i];
    for (int k = 0; k < (int)sizeof(struct dirent); k++)
        p[k] = 0;

    return dir_save();
}


int fs_format(void)
{
    for (int i = 0; i < SECTOR_SIZE; i++)
        dir.raw[i] = 0;

    return dir_save();
}
