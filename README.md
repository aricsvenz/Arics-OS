# ARICS OS V1.0
# Amol Singh (https://amolsingh.in)

A tiny operating system written from scratch — no Linux, no Windows, no libraries underneath it. It boots straight off a virtual disk, takes over the machine, and gives you a working command prompt.

Everything here is built by hand: the bootloader, the kernel, the keyboard and disk drivers, the memory manager, and the shell.

```
                          A R I C S   O S

            32 bit protected mode, written from scratch
               Ring 0 kernel  -  Ring 3 shell  -  no BIOS

                        Press any key to continue
```

---

## What it actually does

- **Boots itself.** A 512-byte bootloader loads the kernel off the disk and switches the CPU into 32-bit protected mode.
- **Talks to the hardware directly.** Screen (VGA text mode), keyboard, timer, and hard disk (ATA) drivers are all written here.
- **Has a real security boundary.** The kernel runs in ring 0 (full power). The shell runs in ring 3 (restricted). The shell can only ask the kernel for things through system calls — the CPU itself enforces this, and the `fault` command demonstrates it.
- **Has memory protection.** Paging is on, so touching memory that isn't mapped crashes cleanly with a page fault instead of silently corrupting things — try the `poke` command.
- **Has a filesystem.** You can create, read, list, and delete files. They survive reboots because they're written to the disk image.

---

## What you need

Three free tools. Install them, then note where they landed — you may need to tell the build script.

| Tool | What it's for | Where to get it |
|---|---|---|
| **NASM** | Assembles the `.asm` files | https://www.nasm.us/ |
| **w64devkit** | Provides `gcc`, `ld`, `objcopy` to compile the C files | https://github.com/skeeto/w64devkit/releases |
| **QEMU** | The virtual PC you'll boot the OS on | https://www.qemu.org/download/#windows |

You'll also need **Windows with PowerShell** (already on your machine).

> **Note:** You do *not* need to install this on a real computer. QEMU pretends to be a PC, so nothing on your actual machine is touched.

---

## Step 1 — Point the build script at your tools

Open [build.ps1](build.ps1) and check these two lines near the top:

```powershell
$Nasm   = "C:\Users\Amol\AppData\Local\bin\NASM\nasm.exe"
$DevKit = "C:\Users\Amol\AppData\Local\bin\w64devkit\bin"
```

Change them to wherever *you* installed NASM and w64devkit. (If NASM is already on your PATH, the script will find it on its own.)

---

## Step 2 — Build it

Open PowerShell in the project folder and run:

```powershell
.\build.ps1
```

If all goes well you'll see something like:

```
boot.bin   : 512 bytes
kernel.bin : 9880 bytes  (6504 free of 16384)
os.bin     : 50176 bytes  (98 sectors)
filesystem : 65 sectors at LBA 33  (preserved from previous image)
```

That produced **`os.bin`** — the complete disk image, bootloader + kernel + filesystem in one file.

> Your saved files are preserved across rebuilds. The script copies the old filesystem into the new image instead of wiping it.

---

## Step 3 — Run it

```powershell
& "C:\Program Files\qemu\qemu-system-i386.exe" -drive format=raw,file=os.bin
```

(Adjust the path if QEMU is installed elsewhere.)

A window opens, the splash screen appears, you press a key, and you get:

```
AOS>
```

That's your prompt. Type `help`.

To quit, just close the QEMU window.

---

## Commands

| Command | What it does |
|---|---|
| `help` | List all commands |
| `clear` | Clear the screen |
| `echo <text>` | Print the text back |
| `about` | Show OS version info |
| `sysinfo` | Show detected hardware (memory, disk, CPU) |
| `ls` | List saved files |
| `write <name>` | Create a file — type lines, then a single `.` on its own line to save |
| `read <name>` | Print a file's contents |
| `rm <name>` | Delete a file |
| `format` | Erase all files |
| `fault` | Deliberately break the rules — shows the CPU blocking a ring 3 program |
| `poke` | Deliberately touch unmapped memory — shows the page fault handler |
| `reboot` | Restart the machine |

### Try this first

```
AOS> write notes
Enter text. A single . on a line saves and exits.
1> hello from my own operating system
2> .
saved 36 bytes

AOS> ls
  notes  36 bytes

AOS> read notes
hello from my own operating system
```

Now reboot (or close QEMU and re-run it) and type `ls` again — the file is still there.

---

## How the pieces fit together

```
os.bin  (the disk image)
  |
  +-- sector 0        boot.bin      the bootloader
  +-- sectors 1-32    kernel.bin    the kernel + shell
  +-- sector 33       directory     names and sizes of your files
  +-- sectors 34+     file data     the files themselves
```

| File | What's in it |
|---|---|
| [boot.asm](boot.asm) | The bootloader. Loads the kernel, asks the BIOS about the hardware, enables A20, switches to 32-bit mode. |
| [kernel.asm](kernel.asm) | The kernel core: GDT, IDT, VGA / keyboard / timer / ATA drivers, system call table. |
| [entry.asm](entry.asm) | 32-bit startup and the privilege-level machinery that drops into ring 3. |
| [isr.asm](isr.asm) | Interrupt and exception handler stubs. |
| [kernel.c](kernel.c) | The C side of the kernel. |
| [paging.c](paging.c) | Turns on the MMU and identity-maps the first 4 MB. |
| [fs.c](fs.c) | The filesystem: directory lookup, read, write, delete, format. |
| [shell.c](shell.c) | The shell — a ring 3 program. Reaches the kernel only via `INT 80h`. |
| [linker.ld](linker.ld) | Tells the linker to place the kernel at address `0x8000`. |
| [build.ps1](build.ps1) | Builds everything and assembles the disk image. |

The [backup/](backup/) folder holds earlier versions kept for reference, and [OS FILES/](OS%20FILES/) holds previously built images (v1, v2, v3).

---

## If something goes wrong

**"gcc not found at ..."**
`$DevKit` in [build.ps1](build.ps1) points at the wrong folder. It must be the `bin` folder inside w64devkit.

**"nasm.exe not found"**
Same idea — fix `$Nasm`, or add NASM to your PATH.

**".\build.ps1 is not digitally signed"**
PowerShell is blocking scripts. Allow them for this session only:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

**"kernel.bin is N bytes but the bootloader only loads 32 sectors"**
The kernel outgrew its space. Raise `KERNEL_SECTORS` in [boot.asm](boot.asm) *and* `$KernelSectors` in [build.ps1](build.ps1) to the same larger number.

**QEMU opens then shows a blank screen**
Make sure you passed `format=raw` and pointed at `os.bin` (not `kernel.bin` or `boot.bin`).

---

## A note on why it's built this way

The bootloader is the only 16-bit code in the project. Once it hands over, the kernel is 100% 32-bit — which is what lets the kernel be linked from object files and mixed with C. The moment protected mode is on, the BIOS is gone for good, so everything the OS wants to know about the hardware is asked *before* the switch and stashed at a fixed address for the kernel to pick up.

Assembly is used where C genuinely can't reach: control registers, segment selectors, interrupt stubs, and the `REP INSW` disk transfers. Everything else — the filesystem, the paging setup, the shell — is C.
