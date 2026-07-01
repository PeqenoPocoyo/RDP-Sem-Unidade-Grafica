# ============================================================
# Install-RustDesk.ps1
# Instala o RustDesk silenciosamente, registra como SERVICO do
# Windows (funciona antes/sem login, essencial p/ bancada sem
# monitor), define senha permanente e configura o modo de
# aprovacao "somente senha" (conecta sem exigir clique local).
# Ao final, imprime e ANUNCIA POR VOZ o ID e a senha.
#
# Uso (PowerShell elevado - Win+R > powershell > Ctrl+Shift+Enter):
#   irm https://SEU_HOST/Install-RustDesk.ps1 | iex
#
# Senha fixa em vez de gerada aleatoriamente:
#   $RustDeskPassword = 'SuaSenhaForte123'; irm https://SEU_HOST/Install-RustDesk.ps1 | iex
#
# Sem anuncio por voz:
#   $Mute = $true; irm https://SEU_HOST/Install-RustDesk.ps1 | iex
# ============================================================

if (-not (Test-Path variable:Mute)) { $Mute = $false }
if (-not (Test-Path variable:RustDeskPassword) -or [string]::IsNullOrWhiteSpace($RustDeskPassword)) {
    $RustDeskPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 14 | ForEach-Object { [char]$_ })
}

# --- Checa elevacao ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERRO: execute em PowerShell como Administrador (Win+R > powershell > Ctrl+Shift+Enter)." -ForegroundColor Red
    exit 1
}

$work = "$env:TEMP\rustdesk-deploy"
New-Item -ItemType Directory -Force -Path $work | Out-Null

# --- Descobre a ultima versao estavel (com fallback fixo) ---
Write-Host "Verificando ultima versao do RustDesk..."
$fallbackVersion = '1.4.8'
try {
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' -UseBasicParsing
    $version = $rel.tag_name.TrimStart('v')
    if ([string]::IsNullOrWhiteSpace($version)) { $version = $fallbackVersion }
} catch {
    $version = $fallbackVersion
}
$exeUrl  = "https://github.com/rustdesk/rustdesk/releases/download/$version/rustdesk-$version-x86_64.exe"
$exePath = Join-Path $work 'rustdesk.exe'

Write-Host "Baixando RustDesk $version..."
try {
    Invoke-WebRequest -Uri $exeUrl -OutFile $exePath -UseBasicParsing
} catch {
    Write-Host "ERRO ao baixar o instalador: $_" -ForegroundColor Red
    exit 1
}

# --- Instalacao silenciosa (NAO usar -Wait: o processo fica residente apos instalar) ---
Write-Host "Instalando..."
Start-Process -FilePath $exePath -ArgumentList @('--silent-install', 'printer=0')

$installDir = "$env:ProgramFiles\RustDesk"
$tries = 0
while (-not (Test-Path "$installDir\rustdesk.exe") -and $tries -lt 20) {
    Start-Sleep -Seconds 2
    if (-not (Test-Path "$installDir\rustdesk.exe")) { $installDir = "${env:ProgramFiles(x86)}\RustDesk" }
    $tries++
}
if (-not (Test-Path "$installDir\rustdesk.exe")) {
    Write-Host "ERRO: instalacao nao encontrada em Program Files." -ForegroundColor Red
    exit 1
}
Write-Host "Instalado em $installDir."
Set-Location $installDir

# --- Registra como servico do Windows (roda mesmo sem ninguem logado) ---
Write-Host "Registrando servico..."
Start-Process -FilePath ".\rustdesk.exe" -ArgumentList '--install-service'
Start-Sleep -Seconds 10
$svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
$tries = 0
while ((-not $svc -or $svc.Status -ne 'Running') -and $tries -lt 10) {
    Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    $tries++
}

Start-Sleep -Seconds 3

# --- ID permanente da maquina (com retry: pode levar alguns segundos apos instalar) ---
Write-Host "Aguardando RustDesk gerar o ID..."
$rdId = $null
$idTries = 0
while ([string]::IsNullOrWhiteSpace($rdId) -and $idTries -lt 15) {
    $out  = & .\rustdesk.exe --get-id 2>$null
    $last = ($out | Select-Object -Last 1)
    if ($last -match '^\d{6,}$') { $rdId = $last }
    if ([string]::IsNullOrWhiteSpace($rdId)) { Start-Sleep -Seconds 2 }
    $idTries++
}
if ([string]::IsNullOrWhiteSpace($rdId)) {
    Write-Host "AVISO: nao consegui ler o ID automaticamente. Rode manualmente: cd '$installDir'; .\rustdesk.exe --get-id" -ForegroundColor Yellow
}

# --- Senha permanente ---
& .\rustdesk.exe --password $RustDeskPassword | Out-Null

# --- Modo "somente senha": conecta sem clique local de aprovacao ---
function Set-RustDeskOption {
    param([string]$TomlPath, [string]$Key, [string]$Value)
    if (-not (Test-Path $TomlPath)) { return }
    $content = Get-Content $TomlPath -Raw
    if ($null -eq $content) { $content = '' }
    if ($content -notmatch '(?m)^\[options\]') { $content += "`n[options]`n" }
    $keyPattern = "(?m)^$([regex]::Escape($Key))\s*=.*$"
    if ($content -match $keyPattern) {
        $content = $content -replace $keyPattern, "$Key = '$Value'"
    } else {
        $content = $content -replace '\[options\]', "[options]`n$Key = '$Value'"
    }
    Set-Content -Path $TomlPath -Value $content -Encoding UTF8 -NoNewline
}

Stop-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$serviceToml = "$env:SystemRoot\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml"
$userToml    = "$env:APPDATA\RustDesk\config\RustDesk2.toml"

foreach ($toml in @($serviceToml, $userToml)) {
    try {
        Set-RustDeskOption -TomlPath $toml -Key 'approve-mode' -Value 'password'
        Set-RustDeskOption -TomlPath $toml -Key 'allow-logon-screen-password' -Value 'Y'
        Set-RustDeskOption -TomlPath $toml -Key 'enable-lan-discovery' -Value 'Y'
    } catch {
        Write-Host "Aviso: nao consegui ajustar $toml ($_)" -ForegroundColor Yellow
    }
}

Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

# --- Regra de firewall (precaucao para modo P2P direto na LAN) ---
New-NetFirewallRule -DisplayName 'RustDesk' -Direction Inbound -Program "$installDir\rustdesk.exe" -Action Allow -ErrorAction SilentlyContinue | Out-Null

Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host " RustDesk instalado e configurado" -ForegroundColor Green
Write-Host "================================================"
Write-Host " Computador        : $env:COMPUTERNAME"
Write-Host " ID de conexao     : $rdId   <- digite isso no campo 'ID' do app"
Write-Host " Senha             : $RustDeskPassword"
Write-Host " (nao existe campo 'usuario' no RustDesk, so ID + senha)"
Write-Host "================================================"

# --- Anuncia ID e senha por voz (util sem monitor conectado) ---
if (-not $Mute) {
    try {
        Add-Type -AssemblyName System.Speech
        $voice  = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $vozes  = $voice.GetInstalledVoices() | Where-Object { $_.Enabled }
        if ($vozes.Count -eq 0) {
            Write-Host "Nenhuma voz de sintese instalada neste Windows (Config > Hora e Idioma > Fala). TTS pulado." -ForegroundColor Yellow
        } else {
            try { $voice.SelectVoiceByHints('NotSet', 'NotSet', 0, [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')) } catch {}
            $idFalado    = if ($rdId) { ($rdId.ToCharArray() -join ' ') } else { 'indisponivel, veja o terminal' }
            $senhaFalada = if ($RustDeskPassword) { ($RustDeskPassword.ToCharArray() -join ' ') } else { 'indisponivel' }
            $texto = "RustDesk instalado no computador $env:COMPUTERNAME. I D $idFalado. Senha $senhaFalada."
            $voice.Speak($texto)
            $voice.Speak($texto)
        }
    } catch {
        Write-Host "Erro no sintetizador de voz: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
