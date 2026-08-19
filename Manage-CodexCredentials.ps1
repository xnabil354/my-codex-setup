[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Good([string]$Message) { Write-Host "[ OK ] $Message" -ForegroundColor Green }
function Warn([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Mask-Secret([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '<kosong>' }
    return "panjang=$($Value.Length)"
}
function Get-CurrentSecret([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name, 'User')
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable($Name, 'Process') }
    return $value
}
function Read-Secret([string]$Prompt) {
    $secure = Read-Host "$Prompt (paste: Ctrl+V, Ctrl+Shift+V, Shift+Insert, klik kanan, atau ketik CLIPBOARD)" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    if ($null -ne $value) { $value = $value.Trim() }
    if ($value -and [string]::Equals($value, 'CLIPBOARD', [StringComparison]::OrdinalIgnoreCase)) {
        try {
            $clipboard = Get-Clipboard -Raw -ErrorAction Stop
            $value = if ($null -ne $clipboard) { $clipboard.Trim() } else { '' }
        }
        catch { Warn 'Clipboard tidak dapat dibaca. Coba paste langsung dengan Ctrl+V atau klik kanan.'; $value = '' }
    }
    return $value
}
function Set-Secret([string]$Name) {
    $existing = Get-CurrentSecret $Name
    $value = Read-Secret "Masukkan $Name terbaru (Enter untuk mempertahankan yang lama)"
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($existing) { Info "$Name tetap dipakai ($(Mask-Secret $existing))." }
        else { Warn "$Name belum diisi." }
        return $existing
    }
    [Environment]::SetEnvironmentVariable($Name, $value, 'User')
    [Environment]::SetEnvironmentVariable($Name, $value, 'Process')
    $user = [Environment]::GetEnvironmentVariable($Name, 'User')
    $process = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($user -ne $value -or $process -ne $value) {
        throw "$Name input diterima tetapi gagal diverifikasi dari environment user/process."
    }
    Good "$Name terdeteksi dan tersimpan ($(Mask-Secret $value))."
    return $value
}
function Status([string]$Name) {
    if (Get-CurrentSecret $Name) { return 'tersimpan' }
    return 'belum ada'
}

Write-Host '=== Codex Vibe Credential Manager ===' -ForegroundColor White
$done = $false
while (-not $done) {
    Write-Host ''
    Write-Host 'Pilih API key yang ingin diinput atau diganti:'
    Write-Host "1. 9Router API key [$(Status 'NINEROUTER_API_KEY')]"
    Write-Host "2. MCP Stitch API key [$(Status 'STITCH_API_KEY')]"
    Write-Host "3. MCP TestSprite API key [$(Status 'TESTSPRITE_API_KEY')]"
    Write-Host '4. Selesai'
    $choice = Read-Host 'Pilih [1-4]'
    if ($null -eq $choice) { $choice = '' } else { $choice = $choice.Trim() }
    switch ($choice) {
        '1' { [void](Set-Secret 'NINEROUTER_API_KEY') }
        '2' { [void](Set-Secret 'STITCH_API_KEY') }
        '3' { [void](Set-Secret 'TESTSPRITE_API_KEY') }
        '4' { $done = $true }
        default { Warn 'Pilihan tidak valid. Masukkan 1, 2, 3, atau 4.' }
    }
}
Good 'Credential selesai diproses.'
Warn 'Jika Codex atau VS Code sedang terbuka, tutup dan buka kembali agar API key terbaru terbaca.'