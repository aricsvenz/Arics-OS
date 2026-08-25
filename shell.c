/* ============================================================
 * SHELL  -  A RING 3 PROGRAM
 * AUTHOR - AMOL SINGH (https://amolsingh.in) | aricsvenz@gmail.com
 * ============================================================
 *
 * Runs at privilege level 3. It cannot execute IN, OUT, CLI,
 * STI, HLT, LGDT or LTR, and it cannot call kernel functions
 * directly because the kernel's code segment is DPL 0.
 *
 * Everything it needs from the machine it asks for through
 * INT 80h. That boundary is enforced by the CPU, not by good
 * manners, and the "fault" command below proves it.
 *
 * Freestanding C: no standard library, no malloc, no printf.
 * Every helper here is written from scratch.
 * ============================================================ */

/* ---- system call numbers, must match sys_table in kernel.asm ---- */

#define SYS_PUTC         0
#define SYS_PRINT        1
#define SYS_GETKEY       2
#define SYS_CLEAR        3
#define SYS_SYSINFO      4
#define SYS_REBOOT       5
#define SYS_FILE_STAT    6
#define SYS_FILE_READ    7
#define SYS_FILE_WRITE   8
#define SYS_FILE_DELETE  9
#define SYS_FORMAT      10

#define MAX_FILES   16
#define NAME_MAX    11
#define LINE_MAX   256
#define FILE_MAX  2048


/* ============================================================
 * THE ONLY DOOR INTO THE KERNEL
 * ============================================================
 *
 * INT 80h with the call number in EAX and arguments in EBX,
 * ECX, EDX and ESI. The kernel preserves everything except
 * EAX, which comes back as the result.
 * ============================================================ */

static int sys(int n, int a, int b, int c, int d)
{
    int r;
    __asm__ __volatile__("int $0x80"
                         : "=a"(r)
                         : "a"(n), "b"(a), "c"(b), "d"(c), "S"(d)
                         : "memory");
    return r;
}


static void putch(char c)          { sys(SYS_PUTC, (int)(unsigned char)c, 0, 0, 0); }
static void print(const char *s)   { sys(SYS_PRINT, (int)s, 0, 0, 0); }
static int  getkey(void)           { return sys(SYS_GETKEY, 0, 0, 0, 0); }
static void clear_screen(void)     { sys(SYS_CLEAR, 0, 0, 0, 0); }


/* ============================================================
 * SMALL HELPERS
 * ============================================================ */

static void print_n(const char *s, int n)
{
    for (int i = 0; i < n; i++)
        putch(s[i]);
}

static void print_name(const char *s)
{
    for (int i = 0; i < NAME_MAX && s[i]; i++)
        putch(s[i]);
}

static void print_dec(unsigned int v)
{
    char buf[12];
    int n = 0;

    do {
        buf[n++] = (char)('0' + (v % 10));
        v /= 10;
    } while (v);

    while (n)
        putch(buf[--n]);
}

static int str_eq_n(const char *a, const char *b, int n)
{
    for (int i = 0; i < n; i++)
        if (a[i] != b[i])
            return 0;
    return 1;
}

static int str_len(const char *s)
{
    int n = 0;
    while (s[n])
        n++;
    return n;
}


/* ============================================================
 * LINE INPUT
 * ============================================================ */

static char line[LINE_MAX];
static int  line_len;

static void read_line(void)
{
    line_len = 0;

    for (;;) {
        int c = getkey();

        if (c == '\r') {
            putch('\r');
            putch('\n');
            return;
        }

        if (c == '\b') {
            if (line_len > 0) {
                line_len--;
                putch('\b');
            }
            continue;
        }

        /* Added by Nayan - ignore control bytes that are not useful to the
         * line editor instead of silently storing them in command input. */
        if (c < 32 || c > 126)
            continue;

        if (line_len < LINE_MAX) {
            line[line_len++] = (char)c;
            putch((char)c);
        }
    }
}


/* ============================================================
 * COMMAND PARSING
 * ============================================================ */

static const char *name_ptr;
static int         name_len;
static const char *arg_ptr;
static int         arg_len;

static void split_line(void)
{
    /* Added by Nayan - accept leading spaces, repeated separators and
     * trailing spaces without changing the user's actual line buffer. */
    int start = 0;
    int end = line_len;

    while (start < end && line[start] == ' ')
        start++;

    while (end > start && line[end - 1] == ' ')
        end--;

    int i = start;
    while (i < end && line[i] != ' ')
        i++;

    name_ptr = &line[start];
    name_len = i - start;

    while (i < end && line[i] == ' ')
        i++;

    arg_ptr = &line[i];
    arg_len = end - i;
}

static int name_is(const char *want)
{
    return str_len(want) == name_len && str_eq_n(name_ptr, want, name_len);
}

/* Added by Nayan - exact argument matching is useful for confirmations
 * without needing a NUL-terminated command-line buffer. */
static int arg_is(const char *want)
{
    return str_len(want) == arg_len && str_eq_n(arg_ptr, want, arg_len);
}

/* Added by Nayan - filenames longer than the on-disk field used to be
 * silently truncated by write, making the saved name surprising. */
static int filename_arg_ok(void)
{
    if (arg_len == 0) {
        print("missing filename\r\n");
        return 0;
    }

    if (arg_len > NAME_MAX) {
        print("filename too long (max 11 characters)\r\n");
        return 0;
    }

    return 1;
}


/* ============================================================
 * COMMANDS
 * ============================================================ */

static const char *banner =
    "\r\n"
    "==================\r\n"
    " ARICS OS V3.0\r\n"
    "==================\r\n"
    "Shell running in ring 3, written in C. Type help.\r\n"
    "\r\n";

static void cmd_help(void)
{
    print("help    - show this list\r\n"
          "clear   - clear the screen\r\n"
          "echo    - print the rest of the line\r\n"
          "about   - system information\r\n"
          "version - show OS version\r\n"
          "sysinfo - hardware information\r\n"
          "fault   - try a privileged instruction and get caught\r\n"
          "poke    - touch unmapped memory and get a page fault\r\n"
          "reboot  - restart the machine\r\n"
          "ls      - list files\r\n"
          "read    - show a file (cat is an alias)\r\n"
          "write   - create or overwrite a file\r\n"
          "rm      - delete a file\r\n"
          "format YES - clear the directory\r\n");
}

static void cmd_clear(void)
{
    clear_screen();
    print(banner);
}

static void cmd_echo(void)
{
    print_n(arg_ptr, arg_len);
    print("\r\n");
}

static void cmd_about(void)
{
    print("ARICS OS V3.0\r\n"
          "Ring 0 kernel in assembly, ring 3 shell in C\r\n"
          "INT 80h system calls, no BIOS after boot\r\n");
}

/* Added by Nayan - a dedicated version command makes scripts and users
 * able to query the release without parsing the full about output. */
static void cmd_version(void)
{
    print("ARICS OS V3.0\r\n");
}

static void cmd_sysinfo(void)
{
    sys(SYS_SYSINFO, 0, 0, 0, 0);
}

static void cmd_reboot(void)
{
    print("Rebooting...\r\n");
    sys(SYS_REBOOT, 0, 0, 0, 0);
}

static void cmd_fault(void)
{
    print("Executing CLI from ring 3...\r\n");
    __asm__ __volatile__("cli");
    print("this line is never reached\r\n");
}

static void cmd_poke(void)
{
    print("Writing to unmapped memory at 0x40000000...\r\n");
    *(volatile unsigned int *)0x40000000 = 0x1234;
    print("this line is never reached\r\n");
}


/* ============================================================
 * FILES
 * ============================================================ */

struct dirent {
    unsigned char  flags;
    char           name[NAME_MAX];
    unsigned short start_lba;
    unsigned short length;
} __attribute__((packed));

static struct dirent entry;
static char          filebuf[FILE_MAX];
static char          namebuf[NAME_MAX + 1];
static int           namebuf_len;

static void cmd_ls(void)
{
    int found = 0;

    /* Added by Nayan - fs_stat now distinguishes empty slots (0) from an
     * actual disk error (-1). The previous boolean check treated -1 as a
     * valid file and could print stale directory data, making ls appear
     * broken when ATA access failed. */
    for (int i = 0; i < MAX_FILES; i++) {
        int status = sys(SYS_FILE_STAT, i, (int)&entry, 0, 0);

        if (status < 0) {
            print("ls: filesystem read error\r\n");
            return;
        }

        if (status == 0)
            continue;

        found = 1;
        print_name(entry.name);
        print("  ");
        print_dec(entry.length);
        print(" bytes\r\n");
    }

    if (!found)
        print("(no files)\r\n");
}

static void cmd_read(void)
{
    if (!filename_arg_ok()) {
        print("usage: read <name>\r\n");
        return;
    }

    int n = sys(SYS_FILE_READ, (int)arg_ptr, arg_len, (int)filebuf, 0);

    if (n < 0)
        print("file not found or filesystem error\r\n");
    else
        print_n(filebuf, n);
}

static void cmd_rm(void)
{
    if (!filename_arg_ok()) {
        print("usage: rm <name>\r\n");
        return;
    }

    if (sys(SYS_FILE_DELETE, (int)arg_ptr, arg_len, 0, 0) < 0)
        print("file not found or filesystem error\r\n");
    else
        print("removed\r\n");
}

static void cmd_format(void)
{
    /* Added by Nayan - formatting is destructive, so require an explicit
     * confirmation token instead of wiping the directory on a typo. */
    if (!arg_is("YES")) {
        print("usage: format YES\r\n");
        return;
    }

    if (sys(SYS_FORMAT, 0, 0, 0, 0) < 0)
        print("disk error\r\n");
    else
        print("directory cleared\r\n");
}

static void cmd_write(void)
{
    if (!filename_arg_ok()) {
        print("usage: write <name>\r\n");
        return;
    }

    namebuf_len = arg_len;
    for (int i = 0; i < namebuf_len; i++)
        namebuf[i] = arg_ptr[i];

    print("Enter text. A single . on a line saves and exits.\r\n");

    int used  = 0;
    int lines = 0;

    for (;;) {
        print_dec((unsigned int)lines + 1);
        print("> ");

        read_line();

        if (line_len == 1 && line[0] == '.')
            break;

        if (used + line_len + 2 > FILE_MAX) {
            print("file full, line ignored\r\n");
            continue;
        }

        for (int i = 0; i < line_len; i++)
            filebuf[used++] = line[i];

        filebuf[used++] = '\r';
        filebuf[used++] = '\n';
        lines++;
    }

    if (sys(SYS_FILE_WRITE, (int)namebuf, namebuf_len, (int)filebuf, used) < 0) {
        print("disk error\r\n");
        return;
    }

    print("saved ");
    print_dec((unsigned int)used);
    print(" bytes\r\n");
}


/* ============================================================
 * DISPATCH
 * ============================================================ */

struct command {
    const char *name;
    void      (*fn)(void);
};

static const struct command commands[] = {
    { "help",    cmd_help    },
    { "clear",   cmd_clear   },
    { "echo",    cmd_echo    },
    { "about",   cmd_about   },
    { "version", cmd_version },
    { "sysinfo", cmd_sysinfo },
    { "system",  cmd_sysinfo },
    { "fault",   cmd_fault   },
    { "poke",    cmd_poke    },
    { "reboot",  cmd_reboot  },
    { "ls",      cmd_ls      },
    { "read",    cmd_read    },
    { "cat",     cmd_read    },
    { "write",   cmd_write   },
    { "rm",      cmd_rm      },
    { "format",  cmd_format  },
    { 0,           0           }
};

static void run_command(void)
{
    if (line_len == 0)
        return;

    split_line();

    if (name_len == 0)
        return;

    for (int i = 0; commands[i].name; i++) {
        if (name_is(commands[i].name)) {
            commands[i].fn();
            return;
        }
    }

    print("Unknown command: ");
    print_n(name_ptr, name_len);
    print("\r\n");
}


/* ============================================================
 * ENTRY
 * ============================================================ */

void shell_main(void)
{
    print(banner);

    for (;;) {
        print("AOS> ");
        read_line();
        run_command();
    }
}
