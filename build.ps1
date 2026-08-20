# ============================================================
# ARICS OS build script
# ============================================================
#
# Produces os.bin:
#
#     sector 1      -> boot.bin     (boot.asm, the MBR)
#     sectors 2..33 -> kernel.bin   (kernel.asm, padded)
#
# kernel.asm pulls in three files:
#
#     entry.asm   32 bit entry and privilege core, never becomes C
#     isr.asm     interrupt stubs, never becomes C
#     shell.asm   the ring 3 program
#
# KERNEL_SECTORS in boot.asm decides how many sectors the
# bootloader reads. $KernelSectors below MUST match it, or the
# bootloader silently loads a truncated kernel and jumps into it.
# ============================================================

$ErrorActionPreference = 'Stop'

$KernelSectors = 32
$SectorSize    = 512
$Capacity      = $KernelSectors * $SectorSize

# Filesystem geometry. These must match DIR_LBA / DATA_LBA /
# MAX_FILES / FILE_SECTORS in kernel.asm.
$DirSectors    = 1
$MaxFiles      = 16
$FileSectors   = 4
$FsSectors     = $DirSectors + ($MaxFiles * $FileSectors)
$FsOffset      = $SectorSize + $Capacity
$FsBytes       = $FsSectors * $SectorSize
$TotalBytes    = $FsOffset + $FsBytes

$Dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# ------------------------------------------------------------
# Locate nasm
# ------------------------------------------------------------

$Nasm = "C:\Users\Amol\AppData\Local\bin\NASM\nasm.exe"

# ------------------------------------------------------------
# Locate the C toolchain (w64devkit)
#
# gcc must find its sibling tools (as, cc1) on PATH, so the
# whole bin directory is prepended rather than calling gcc by
# full path.
# ------------------------------------------------------------

$DevKit = "C:\Users\Amol\AppData\Local\bin\w64devkit\bin"

if (-not (Test-Path (Join-Path $DevKit 'gcc.exe'))) {
    throw "gcc not found at $DevKit - edit $DevKit at the top of this script"
}

$env:PATH = "$DevKit;$env:PATH"

if (-not (Test-Path $Nasm)) {
    try   { $Nasm = (Get-Command nasm.exe -ErrorAction Stop).Source }
    catch { throw "nasm.exe not found. Edit `$Nasm at the top of this script." }
}

# ------------------------------------------------------------
# Assemble
# ------------------------------------------------------------

Push-Location $Dir
try {
    & $Nasm -f bin boot.asm -o boot.bin
    if ($LASTEXITCODE -ne 0) { throw "bootloader assembly failed" }

    # --------------------------------------------------------
    # The kernel is assembled to an object file and linked,
    # rather than emitted as a flat binary, so that C can be
    # linked in alongside it.
    #
    # PE ld cannot write --oformat binary directly, so we link
    # to PE and flatten it with objcopy. .reloc is dropped
    # because a flat binary is never relocated.
    # --------------------------------------------------------

    & $Nasm -f win32 kernel.asm -o kernel_asm.o
    if ($LASTEXITCODE -ne 0) { throw "kernel assembly failed" }

    & gcc -ffreestanding -fno-leading-underscore -fno-pie -fno-stack-protector -fno-builtin -Wall -Wextra -c kernel.c -o kernel_c.o
    if ($LASTEXITCODE -ne 0) { throw "C compilation failed" }

    & gcc -ffreestanding -fno-leading-underscore -fno-pie -fno-stack-protector -fno-builtin -Wall -Wextra -c shell.c -o shell_c.o
    if ($LASTEXITCODE -ne 0) { throw "shell.c compilation failed" }

    & gcc -ffreestanding -fno-leading-underscore -fno-pie -fno-stack-protector -fno-builtin -Wall -Wextra -c fs.c -o fs_c.o
    if ($LASTEXITCODE -ne 0) { throw "fs.c compilation failed" }

    & gcc -ffreestanding -fno-leading-underscore -fno-pie -fno-stack-protector -fno-builtin -Wall -Wextra -c paging.c -o paging_c.o
    if ($LASTEXITCODE -ne 0) { throw "paging.c compilation failed" }

    & ld -T linker.ld kernel_asm.o kernel_c.o fs_c.o paging_c.o shell_c.o -o kernel.pe
    if ($LASTEXITCODE -ne 0) { throw "link failed" }

    & objcopy -O binary -R .reloc kernel.pe kernel.bin
    if ($LASTEXITCODE -ne 0) { throw "objcopy failed" }

    # --------------------------------------------------------
    # Validate the bootloader: exactly one sector, carrying
    # the boot signature the BIOS looks for.
    # --------------------------------------------------------

    $S1 = [IO.File]::ReadAllBytes((Join-Path $Dir 'boot.bin'))

    if ($S1.Length -ne $SectorSize) {
        throw "boot.bin is $($S1.Length) bytes, expected $SectorSize"
    }
    if ($S1[510] -ne 0x55 -or $S1[511] -ne 0xAA) {
        throw "boot.bin is missing the 0xAA55 boot signature"
    }

    # --------------------------------------------------------
    # Validate the kernel fits in the sectors the bootloader reads.
    # --------------------------------------------------------

    $S2 = [IO.File]::ReadAllBytes((Join-Path $Dir 'kernel.bin'))

    if ($S2.Length -gt $Capacity) {
        throw ("kernel.bin is $($S2.Length) bytes but the bootloader only loads " +
               "$KernelSectors sectors ($Capacity bytes). Raise KERNEL_SECTORS " +
               "in boot.asm and `$KernelSectors in this script.")
    }

    # --------------------------------------------------------
    # Pad the kernel and concatenate
    # --------------------------------------------------------

    $Padded = New-Object byte[] $Capacity
    [Array]::Copy($S2, $Padded, $S2.Length)
    [IO.File]::WriteAllBytes((Join-Path $Dir 'kernel_padded.bin'), $Padded)

    $Os = New-Object byte[] $TotalBytes
    [Array]::Copy($S1, $Os, $SectorSize)
    [Array]::Copy($Padded, 0, $Os, $SectorSize, $Capacity)

    # ------------------------------------------------------------
    # Carry the filesystem across a rebuild.
    #
    # The directory and file data live in the image, so writing a
    # fresh one would wipe every file you had created. If the
    # existing image is the right shape, copy its filesystem area
    # into the new one instead of leaving it zeroed.
    # ------------------------------------------------------------

    $OsPath = Join-Path $Dir 'os.bin'
    $Kept = 'formatted empty'

    if (Test-Path $OsPath) {
        $Old = [IO.File]::ReadAllBytes($OsPath)
        if ($Old.Length -eq $TotalBytes) {
            [Array]::Copy($Old, $FsOffset, $Os, $FsOffset, $FsBytes)
            $Kept = 'preserved from previous image'
        }
    }

    [IO.File]::WriteAllBytes($OsPath, $Os)

    $Free = $Capacity - $S2.Length

    Write-Host ""
    Write-Host "boot.bin   : $($S1.Length) bytes"
    Write-Host "kernel.bin : $($S2.Length) bytes  ($Free free of $Capacity)"
    Write-Host "os.bin     : $($Os.Length) bytes  ($($Os.Length / $SectorSize) sectors)"
    Write-Host "filesystem : $FsSectors sectors at LBA $($FsOffset / $SectorSize)  ($Kept)"
    Write-Host ""
    Write-Host 'Run it:  & "C:\Program Files\qemu\qemu-system-i386.exe" -drive format=raw,file=os.bin'
    Write-Host ""
}
finally {
    Pop-Location
}
