# ============================================================
# Install-Spacedesk-Headless.ps1 (VERSÃO CORRIGIDA)
# ============================================================

# [!] ATENÇÃO: Se der erro de download, entre no site do Spacedesk pelo celular,
# veja qual é o link atual do "Windows Driver msi" e cole ele aqui embaixo:
$msiUrl = "https://download.spacedesk.net/current/spacedesk_driver_Win_10_64_v2130.msi"

if (-not (Test-Path variable:Mute)) { $Mute = $false }

# --- TTS: Inicialização ---
$Global:ttsVoice = $null
$Global:ttsOk = $false
if (-not $Mute) {
    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        $Global:ttsVoice = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $vozesInstaladas = $Global:ttsVoice.GetInstalledVoices() | Where-Object { $_.Enabled }
        if ($vozesInstaladas.Count -gt 0) {
            try { $Global:ttsVoice.SelectVoiceByHints('NotSet', 'NotSet', 0, [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')) } catch {}
            $Global:ttsVoice.Rate = -2
            $Global:ttsOk = $true
        }
    } catch { $Global:ttsOk = $false }
}

function Speak-IPAddress {
    param([string]$Label, [string]$Value)
    if (-not $Global:ttsOk -or [string]::IsNullOrWhiteSpace($Value)) { return }
    try {
        $pb = New-Object System.Speech.Synthesis.PromptBuilder
        $pb.AppendText($Label)
        $pb.AppendBreak([System.Speech.Synthesis.PromptBreak]::Medium)
        foreach ($ch in $Value.ToCharArray()) {
            if ($ch -eq '.') { $pb.AppendText(" ponto ") }
            else { $pb.AppendText("$ch") }
            $pb.AppendBreak([System.Speech.Synthesis.PromptBreak]::Short)
        }
        $Global:ttsVoice.Speak($pb)
    } catch {}
}

function Say {
    param([string]$Text, [string]$Color = 'Cyan')
    Write-Host $Text -ForegroundColor $Color
    if ($Global:ttsOk) {
        try { $Global:ttsVoice.Speak($Text) } catch {}
    }
}

Say "Iniciando instalação corrigida do Space Desk." 'Green'

# --- Requisitos Básicos ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Say "Erro. Rode o PowerShell como administrador." 'Red'; exit 1 }

# --- FORÇAR TLS 1.2 / 1.3 & USER-AGENT (A CORREÇÃO DO ERRO) ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

$work = "$env:TEMP\spacedesk-deploy"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$msiPath = Join-Path $work 'spacedesk.msi'

Say "Tentando baixar o instalador com protocolo de segurança atualizado."

$downloadSucesso = $false

# Método 1: Invoke-WebRequest disfarçado de navegador
try {
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UserAgent $UserAgent -UseBasicParsing -TimeoutSec 90 -ErrorAction Stop
    $downloadSucesso = $true
} catch {
    Write-Host "[!] Método 1 falhou. Tentando método alternativo via .NET..." -ForegroundColor Yellow
}

# Método 2: Fallback usando WebClient do .NET (se o Método 1 falhar)
if (-not $downloadSucesso) {
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("user-agent", $UserAgent)
        $webClient.DownloadFile($msiUrl, $msiPath)
        $downloadSucesso = $true
    } catch {
        $downloadSucesso = $false
    }
}

if (-not $downloadSucesso) {
    Say "Erro crítico. Não foi possível baixar o arquivo. O link do Spacedesk pode ter mudado." 'Red'
    Write-Host "[!] Erro: Verifique se o link $msiUrl ainda é válido abrindo-o no navegador de outro aparelho." -ForegroundColor Red
    exit 1
}

Say "Download concluído com sucesso."

# --- Instalação ---
Say "Instalando driver de vídeo virtual. Por favor, aguarde."
$Arguments = "/i `"$msiPath`" /qn /norestart"
$Process = Start-Process msiexec.exe -ArgumentList $Arguments -Wait -PassThru

if ($Process.ExitCode -ne 0) {
    Say "Erro na instalação. Código de erro $($Process.ExitCode)" 'Red'
    exit 1
}
Say "Instalação concluída."

# --- Configuração do Serviço ---
$serviceName = "spacedeskService"
Set-Service -Name $serviceName -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name $serviceName -ErrorAction SilentlyContinue

# --- Captura de IPs e encerramento ---
$ips = @()
try {
    $ips = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -notlike '169.254.*' -and $_.ToString() -ne '127.0.0.1' } |
        ForEach-Object { $_.ToString() }
} catch {}

Remove-Item $msiPath -ErrorAction SilentlyContinue

if ($Global:ttsOk) {
    Say "O monitor virtual está pronto no computador $env:COMPUTERNAME."
    if ($ips.Count -gt 0) {
        Say "Conecte usando os endereços:"
        for ($i = 1; $i -le 2; $i++) {
            foreach ($ip in $ips) { Speak-IPAddress -Label "IP" -Value $ip }
            Start-Sleep -Seconds 2
        }
    }
}
