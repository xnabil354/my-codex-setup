param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "aihubmix",
        "kiropecut",
        "cloudflarepecut",
        "gacor",
        "hemat",
        "free",
        "freeopenrouter",
	"grokpecut",
        "tokengo",
	"xkiro",
	"baseten",
	"madedeep",
	"ryznvm",
	"qoder"
    )]
    [string]$Combo
)

$configPath = Join-Path $env:USERPROFILE ".codex\config.toml"

if (-not (Test-Path $configPath)) {
    Write-Error "Config Codex tidak ditemukan: $configPath"
    exit 1
}

$content = Get-Content -Path $configPath -Raw

if ($content -notmatch '(?m)^model\s*=') {
    Write-Error 'Konfigurasi top-level "model" tidak ditemukan.'
    exit 1
}

# Hanya mengganti kemunculan model pertama.
# Tidak mengubah model milik subagent.
$updated = [regex]::Replace(
    $content,
    '(?m)^model\s*=\s*"[^"]*"\s*$',
    "model = `"$Combo`"",
    1
)

Set-Content `
    -Path $configPath `
    -Value $updated `
    -Encoding utf8 `
    -NoNewline

Write-Host ""
Write-Host "Combo Codex global berhasil diganti menjadi: $Combo"
Write-Host "Berlaku untuk seluruh project."
Write-Host "Buat thread Codex baru agar perubahan diterapkan."