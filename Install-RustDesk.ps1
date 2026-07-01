# ============================================================
# Install-RustDesk.ps1
# Instala RustDesk silenciosamente, registra como servico do
# Windows, define senha permanente, configura modo "somente
# senha" (sem clique local), e narra cada etapa por voz (TTS) -
# util para maquinas sem monitor.
#
# Compativel com Windows 7+ / PowerShell 3+ (nao depende dos
# modulos NetSecurity/NetTCPIP, que so existem no Windows 8+).
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

# --- TTS: inicializa uma vez, reusa em todo o script ---
$Global:ttsVoice = $null
$Global:ttsOk = $false
if (-not $Mute) {
    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        $Global:ttsVoice = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $vozesInstaladas = $Global:ttsVoice.GetInstalledVoices() | Where-Object { $_.Enabled }
        if ($vozesInstaladas.Count -gt 0) {
            try { $Global:ttsVoice.SelectVoiceByHints('NotSet', 'NotSet', 0, [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')) } catch {}
            $Global:ttsVoice.Rate = -4
            $Global:ttsOk = $true
        }
    } catch { $Global:ttsOk = $false }
}

# --- Leitura caractere a caractere, anunciando maiuscula/minuscula/numero,
#     com pausa entre cada um - necessario porque falar so a letra nao
#     distingue "A" maiusculo de "a" minusculo por audio. ---
function Speak-Credential {
    param([string]$Label, [string]$Value)
    if (-not $Global:ttsOk -or [string]::IsNullOrWhiteSpace($Value)) { return }
    try {
        $pb = New-Object System.Speech.Synthesis.PromptBuilder
        $pb.AppendText($Label)
        $pb.AppendBreak([System.Speech.Synthesis.PromptBreak]::Medium)
        foreach ($ch in $Value.ToCharArray()) {
            if ($ch -cmatch '[A-Z]')      { $pb.AppendText("maiusculo $ch") }
            elseif ($ch -cmatch '[a-z]')  { $pb.AppendText("minusculo $ch") }
            elseif ($ch -match '[0-9]')   { $pb.AppendText("numero $ch") }
            else                          { $pb.AppendText("$ch") }
            $pb.AppendBreak([System.Speech.Synthesis.PromptBreak]::Medium)
        }
        $Global:ttsVoice.Speak($pb)
    } catch {
        Write-Host "Erro ao falar '$Label' por voz: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Say {
    param([string]$Text, [string]$Color = 'Cyan')
    Write-Host $Text -ForegroundColor $Color
    if ($Global:ttsOk) {
        try { $Global:ttsVoice.Speak($Text) } catch {}
    }
}

Say "Iniciando verificacao de requisitos." 'Green'

# --- Requisito 1: elevacao ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Say "Erro. Este terminal nao esta como administrador. Abra o PowerShell como administrador e tente novamente." 'Red'
    exit 1
}
Say "Permissao de administrador confirmada."

# --- Requisito 2: versao do PowerShell (irm/iex exigem PS3+) ---
$psMajor = $PSVersionTable.PSVersion.Major
Say "PowerShell versao $psMajor detectado."
if ($psMajor -lt 3) {
    Say "Erro. Este Windows tem PowerShell muito antigo, versao minima e a tres. Atualize o Windows Management Framework." 'Red'
    exit 1
}

# --- Requisito 3: conectividade com a internet ---
Say "Testando conexao com a internet."
$netOk = $false
try {
    $testResp = Invoke-WebRequest -Uri 'https://github.com' -UseBasicParsing -TimeoutSec 10
    if ($testResp.StatusCode -ge 200 -and $testResp.StatusCode -lt 400) { $netOk = $true }
} catch { $netOk = $false }
if ($netOk) {
    Say "Internet: conectada."
} else {
    Say "Aviso. Nao consegui confirmar acesso a internet. O download pode falhar. Continuando mesmo assim." 'Yellow'
}

# --- Pasta de trabalho ---
$work = "$env:TEMP\rustdesk-deploy"
New-Item -ItemType Directory -Force -Path $work | Out-Null

# --- Descobre a ultima versao estavel (com fallback fixo) ---
Say "Verificando ultima versao do RustDesk."
$fallbackVersion = '1.4.8'
try {
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' -UseBasicParsing -TimeoutSec 15
    $version = $rel.tag_name.TrimStart('v')
    if ([string]::IsNullOrWhiteSpace($version)) { $version = $fallbackVersion }
} catch {
    $version = $fallbackVersion
}
Say "Versao selecionada: $version."

$exeUrl  = "https://github.com/rustdesk/rustdesk/releases/download/$version/rustdesk-$version-x86_64.exe"
$exePath = Join-Path $work 'rustdesk.exe'

Say "Baixando instalador."
try {
    Invoke-WebRequest -Uri $exeUrl -OutFile $exePath -UseBasicParsing -TimeoutSec 120
} catch {
    Say "Erro ao baixar o instalador. $($_.Exception.Message)" 'Red'
    exit 1
}
Say "Download concluido."

# --- Instalacao silenciosa (NAO usar -Wait: o processo fica residente apos instalar) ---
Say "Instalando RustDesk, sem interacao de menus."
Start-Process -FilePath $exePath -ArgumentList @('--silent-install', 'printer=0')

$candidateDirs = @("$env:ProgramFiles\RustDesk", "${env:ProgramFiles(x86)}\RustDesk")
$installDir = $null
$tries = 0
while (-not $installDir -and $tries -lt 25) {
    foreach ($c in $candidateDirs) {
        if (Test-Path "$c\rustdesk.exe") { $installDir = $c; break }
    }
    if (-not $installDir) { Start-Sleep -Seconds 2 }
    $tries++
}
if (-not $installDir) {
    Say "Erro. Instalacao nao encontrada apos aguardar. Abortando." 'Red'
    exit 1
}
Say "Instalacao concluida em $installDir."
Set-Location $installDir

# --- Registra como servico do Windows (roda mesmo sem ninguem logado) ---
Say "Registrando servico do Windows."
Start-Process -FilePath ".\rustdesk.exe" -ArgumentList '--install-service'

$svc = $null
$tries = 0
while ((-not $svc -or $svc.Status -ne 'Running') -and $tries -lt 15) {
    Start-Sleep -Seconds 3
    Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    $svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    $tries++
}
if ($svc -and $svc.Status -eq 'Running') {
    Say "Servico registrado e em execucao."
} else {
    Say "Aviso. Nao consegui confirmar que o servico esta rodando. Vou continuar, mas verifique manualmente depois com Get-Service RustDesk." 'Yellow'
}

Start-Sleep -Seconds 3

# --- ID permanente da maquina ---
# IMPORTANTE: no Windows, rustdesk.exe --get-id nao imprime nada se
# chamado direto - e preciso forcar com Out-String, senao a saida
# fica vazia mesmo funcionando internamente (comportamento documentado).
Say "Obtendo identificador de conexao."
$rdId = $null
$idTries = 0
while ([string]::IsNullOrWhiteSpace($rdId) -and $idTries -lt 15) {
    $raw = (& .\rustdesk.exe --get-id 2>&1 | Out-String)
    $candidate = ($raw -split "`r?`n" | Where-Object { $_ -match '^\d{6,}$' } | Select-Object -Last 1)
    if ($candidate) { $rdId = $candidate.Trim() }
    if ([string]::IsNullOrWhiteSpace($rdId)) { Start-Sleep -Seconds 2 }
    $idTries++
}
if ($rdId) {
    Say "Identificador obtido: $rdId"
} else {
    Say "Aviso. Nao consegui ler o identificador automaticamente. Pode ser uma falha conhecida de linha de comando em algumas versoes do RustDesk. Verifique manualmente rodando rustdesk ponto exe espaco traco traco get-id, com saida forcada por Out-String." 'Yellow'
}

# --- Senha permanente ---
Say "Definindo senha de acesso."
& .\rustdesk.exe --password $RustDeskPassword 2>&1 | Out-Null
Start-Sleep -Seconds 2

# --- Modo "somente senha": conecta sem clique local de aprovacao ---
function Set-RustDeskOption {
    param([string]$TomlPath, [string]$Key, [string]$Value)
    if (-not (Test-Path $TomlPath)) { return $false }
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
    return $true
}

Say "Configurando conexao sem clique de aprovacao local."
Stop-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$serviceToml = "$env:SystemRoot\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml"
$userToml    = "$env:APPDATA\RustDesk\config\RustDesk2.toml"
$configApplied = $false

foreach ($toml in @($serviceToml, $userToml)) {
    try {
        $ok1 = Set-RustDeskOption -TomlPath $toml -Key 'approve-mode' -Value 'password'
        Set-RustDeskOption -TomlPath $toml -Key 'allow-logon-screen-password' -Value 'Y' | Out-Null
        Set-RustDeskOption -TomlPath $toml -Key 'enable-lan-discovery' -Value 'Y' | Out-Null
        if ($ok1) { $configApplied = $true }
    } catch {
        Say "Aviso. Nao consegui ajustar configuracao em $toml." 'Yellow'
    }
}

Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

# --- Verificacao final: config realmente aplicada? ---
$verificado = $false
if (Test-Path $serviceToml) {
    $checkContent = Get-Content $serviceToml -Raw
    if ($checkContent -match "approve-mode\s*=\s*'password'") { $verificado = $true }
}
if ($verificado) {
    Say "Confirmado: aprovacao automatica por senha esta ativa."
} else {
    Say "Aviso. Nao consegui confirmar a configuracao de aprovacao automatica. A conexao pode ainda pedir clique local na primeira tentativa." 'Yellow'
}

$svcFinal = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
if ($svcFinal -and $svcFinal.Status -eq 'Running') {
    Say "Servico confirmado em execucao apos reinicio de configuracao."
} else {
    Say "Aviso. Servico nao esta rodando apos a reconfiguracao. Rode Start-Service RustDesk manualmente." 'Yellow'
}

# --- Firewall (best-effort via netsh, compativel com qualquer Windows; NAO e obrigatorio) ---
# RustDesk conecta por saida (outbound) ao servidor de relay publico por padrao,
# entao isso so importa para o modo P2P direto na LAN - falha aqui nao impede o uso normal.
try {
    netsh advfirewall firewall delete rule name="RustDesk" | Out-Null
    netsh advfirewall firewall add rule name="RustDesk" dir=in action=allow program="$installDir\rustdesk.exe" enable=yes | Out-Null
    Say "Regra de firewall aplicada."
} catch {
    Say "Aviso. Nao consegui ajustar o firewall, mas isso normalmente nao impede a conexao via relay." 'Yellow'
}

# --- IPs locais (informativo apenas - via .NET puro, funciona em qualquer versao) ---
$ips = @()
try {
    $ips = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -notlike '169.254.*' } |
        ForEach-Object { $_.ToString() }
} catch {}

Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host " RustDesk instalado e configurado" -ForegroundColor Green
Write-Host "================================================"
Write-Host " Computador        : $env:COMPUTERNAME"
Write-Host " ID de conexao     : $(if ($rdId) { $rdId } else { 'FALHOU - veja avisos acima' })"
Write-Host " Senha             : $RustDeskPassword"
Write-Host " IP(s) (referencia): $($ips -join ', ')"
Write-Host " (RustDesk nao usa 'usuario' - so ID + senha, no app RustDesk, nao no Windows App)"
Write-Host "================================================"

# --- Leitura final por voz (duas vezes), letra a letra com pausa e caixa anunciada ---
if ($Global:ttsOk) {
    $Global:ttsVoice.Speak("Resumo final. Computador $env:COMPUTERNAME.")
    for ($i = 1; $i -le 2; $i++) {
        Speak-Credential -Label "Identificador" -Value $(if ($rdId) { $rdId } else { $null })
        Speak-Credential -Label "Senha" -Value $RustDeskPassword
    }
} elseif (-not $Mute) {
    Write-Host "Nenhuma voz de sintese instalada neste Windows (Configuracoes > Hora e Idioma > Fala) - narracao por audio nao disponivel." -ForegroundColor Yellow
}
