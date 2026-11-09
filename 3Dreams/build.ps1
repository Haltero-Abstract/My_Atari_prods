$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
# rg-asm.exe : in this folder, otherwise in a neighbouring folder
$assembler = Join-Path $root 'rg-asm.exe'
if (-not (Test-Path $assembler)) {
    $found = Get-ChildItem -Path (Split-Path -Parent $root) -Filter 'rg-asm.exe' -Recurse -Depth 1 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $assembler = $found.FullName } else { throw 'rg-asm.exe not found' }
}
Push-Location $root
try {
    # 3DREAMS.S includes AMIGADSP.S (which includes AMIGADSP.P56) and 3DREAMS.P56
    & $assembler --cpu=68030 '--listing=3DREAMS.LST' '--output=3DREAMS.PRG' '3DREAMS.S'
    if ($LASTEXITCODE -ne 0) { throw "Assembly failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}
