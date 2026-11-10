[CmdletBinding()]
param(
    [string]$Executable = "$PSScriptRoot/../bin/VS2022/Release_x64/Notepad2.exe",
    [switch]$ExpectLegacyFailure
)

$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class SavePromptNative {
    public delegate bool Callback(IntPtr hwnd, IntPtr state);
    [DllImport("user32.dll")] public static extern bool EnumWindows(Callback cb, IntPtr state);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hwnd, Callback cb, IntPtr state);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int size);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hwnd, int id);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr VirtualAllocEx(IntPtr process, IntPtr address, UIntPtr size, uint allocationType, uint protection);
    [DllImport("kernel32.dll")] public static extern bool VirtualFreeEx(IntPtr process, IntPtr address, UIntPtr size, uint freeType);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteProcessMemory(IntPtr process, IntPtr address, byte[] bytes, UIntPtr size, out UIntPtr written);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] bytes, UIntPtr size, out UIntPtr read);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
}
'@

function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Sci($message, $w = 0, $l = 0) {
    [SavePromptNative]::SendMessage($script:editor, $message, [IntPtr]$w, [IntPtr]$l).ToInt64()
}
function Find-Windows {
    $script:dialog = [IntPtr]::Zero
    $script:window = [IntPtr]::Zero
    $processId = $script:app.Id
    $callback = [SavePromptNative+Callback]{ param($handle, $state)
        [uint32]$owner = 0
        $null = [SavePromptNative]::GetWindowThreadProcessId($handle, [ref]$owner)
        if ($owner -eq $processId) {
            $name = New-Object Text.StringBuilder 128
            $null = [SavePromptNative]::GetClassName($handle, $name, 128)
            if ($name.ToString() -like 'Notepad2*') { $script:window = $handle }
            if ($name.ToString() -eq '#32770') { $script:dialog = $handle }
        }
        return $true
    }
    $null = [SavePromptNative]::EnumWindows($callback, [IntPtr]::Zero)
}
function Start-Editor($named) {
    $arguments = @('/n', '/f', ('"'+$ini+'"'))
    if ($named) { $arguments += ('"'+$namedFile+'"') }
    $script:app = Start-Process -FilePath $Executable -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Assert ($script:app.WaitForInputIdle(60000)) 'Editor startup timed out'
    Find-Windows
    Assert ($script:window -ne [IntPtr]::Zero) 'Main window missing'
    $script:editor = [IntPtr]::Zero
    $child = [SavePromptNative+Callback]{ param($handle, $state)
        $name = New-Object Text.StringBuilder 128
        $null = [SavePromptNative]::GetClassName($handle, $name, 128)
        if ($name.ToString() -eq 'Scintilla') { $script:editor = $handle }
        return $true
    }
    $null = [SavePromptNative]::EnumChildWindows($script:window, $child, [IntPtr]::Zero)
    Assert ($script:editor -ne [IntPtr]::Zero) 'Editor window missing'
    $script:processHandle = [SavePromptNative]::OpenProcess(0x38, $false, $script:app.Id)
    Assert ($script:processHandle -ne [IntPtr]::Zero) 'Cannot access test-process memory'
}
function Add-Bytes([byte[]]$bytes) {
    if (-not $bytes.Length) { return }
    $remote = [SavePromptNative]::VirtualAllocEx($script:processHandle, [IntPtr]::Zero, [UIntPtr]$bytes.Length, 0x3000, 4)
    Assert ($remote -ne [IntPtr]::Zero) 'Cannot allocate test-process text'
    try {
        [UIntPtr]$written = [UIntPtr]::Zero
        Assert ([SavePromptNative]::WriteProcessMemory($script:processHandle, $remote, $bytes, [UIntPtr]$bytes.Length, [ref]$written)) 'Cannot write test text'
        $null = Sci 2001 $bytes.Length $remote
    } finally { $null = [SavePromptNative]::VirtualFreeEx($script:processHandle, $remote, [UIntPtr]::Zero, 0x8000) }
}
function Read-Bytes {
    $length = [int](Sci 2006)
    $remote = [SavePromptNative]::VirtualAllocEx($script:processHandle, [IntPtr]::Zero, [UIntPtr]($length+1), 0x3000, 4)
    Assert ($remote -ne [IntPtr]::Zero) 'Cannot allocate read buffer'
    try {
        $null = Sci 2182 ($length+1) $remote
        $bytes = New-Object byte[] $length
        [UIntPtr]$read = [UIntPtr]::Zero
        Assert ([SavePromptNative]::ReadProcessMemory($script:processHandle, $remote, $bytes, [UIntPtr]$length, [ref]$read)) 'Cannot read test text'
        return ,$bytes
    } finally { $null = [SavePromptNative]::VirtualFreeEx($script:processHandle, $remote, [UIntPtr]::Zero, 0x8000) }
}

$Executable = (Resolve-Path $Executable).Path
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('np2-save-prompts-'+[Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testDir
$ini = Join-Path $testDir 'settings.ini'
$namedFile = Join-Path $testDir 'named.txt'
[IO.File]::WriteAllText($ini, "[Settings]`r`nSaveSettings=0`r`nSaveRecentFiles=0`r`n", [Text.Encoding]::Unicode)
[IO.File]::WriteAllText($namedFile, 'named file')
$shortNul = [byte[]]@(0,65,66)
$boundary1022 = New-Object byte[] 1022
$boundary1022[1] = 65
$boundary1023 = New-Object byte[] 1023
$boundary1023[1] = 65
$cases = @(
    @{Name='leading-NUL'; Bytes=$shortNul; LegacyDrops=$true},
    @{Name='whitespace'; Bytes=[Text.Encoding]::UTF8.GetBytes(" `t`r`n"); LegacyDrops=$true},
    @{Name='1022-byte-NUL'; Bytes=$boundary1022; LegacyDrops=$true},
    @{Name='1023-byte-NUL'; Bytes=$boundary1023; LegacyDrops=$false},
    @{Name='empty'; Bytes=[byte[]]@(); LegacyDrops=$false},
    @{Name='named-NUL'; Bytes=$shortNul; LegacyDrops=$false; Named=$true}
)
$observedLoss = 0
foreach ($case in $cases) {
    foreach ($operation in @('New','Open','Close')) {
        $script:processHandle = [IntPtr]::Zero
        try {
            Start-Editor $case.Named
            Add-Bytes $case.Bytes
            $before = Read-Bytes
            $main = $script:window
            if ($operation -eq 'Close') { $null = [SavePromptNative]::PostMessage($main, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) }
            else {
                $command = if ($operation -eq 'New') { 40000 } else { 40001 }
                $null = [SavePromptNative]::PostMessage($main, 0x111, [IntPtr]$command, [IntPtr]::Zero)
            }
            $prompt = $false
            for ($attempt = 0; $attempt -lt 100; ++$attempt) {
                $script:app.Refresh()
                if ($script:app.HasExited) { break }
                Find-Windows
                if ($script:dialog -ne [IntPtr]::Zero) {
                    $prompt = [SavePromptNative]::GetDlgItem($script:dialog,6) -ne [IntPtr]::Zero -and [SavePromptNative]::GetDlgItem($script:dialog,7) -ne [IntPtr]::Zero
                    break
                }
                if ($operation -eq 'New' -and (Sci 2006) -eq 0) { break }
                Start-Sleep -Milliseconds 20
            }
            $expected = $case.Bytes.Length -gt 0 -and -not ($ExpectLegacyFailure -and $case.LegacyDrops)
            Assert ($prompt -eq $expected) "$($case.Name)/${operation}: save prompt=$prompt, expected=$expected"
            if ($prompt) {
                $null = [SavePromptNative]::SendMessage($script:dialog,0x111,[IntPtr]2,[IntPtr]::Zero)
                $after = Read-Bytes
                Assert ([Convert]::ToBase64String($before) -eq [Convert]::ToBase64String($after)) "$($case.Name)/${operation}: Cancel lost content"
            } elseif ($case.LegacyDrops) { ++$observedLoss }
            Write-Output "Passed $($case.Name)/$operation (prompt=$prompt)"
        } finally {
            if ($script:processHandle -ne [IntPtr]::Zero) { $null = [SavePromptNative]::CloseHandle($script:processHandle) }
            if ($script:app -and -not $script:app.HasExited) { Stop-Process -Id $script:app.Id }
        }
    }
}
if ($ExpectLegacyFailure) { Assert ($observedLoss -eq 9) 'Legacy data-loss cases were not reproduced' }
Write-Output "Save-prompt integration passed. Legacy loss cases: $observedLoss. Fixtures: $testDir"
