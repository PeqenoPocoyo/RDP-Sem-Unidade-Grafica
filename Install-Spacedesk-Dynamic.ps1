# ============================================================
# Install-Spacedesk-Dynamic.ps1 (VERSÃO ULTRA-ROBUSTA)
# Varre o site da SpaceDesk, descobre o link atual e instala às cegas.
# ============================================================

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
    if ($Global:ttsOk) { try { $Global:ttsVoice.Speak($Text) } catch {} }
}

function Pensa-E-Fecha {
    param([string]$MsgErro)
    Say $MsgErro 'Red'
    Write-Host "`n[!] A fechar em 15 segundos para dar tempo de ler o erro..." -ForegroundColor Yellow
    Start-Sleep -Seconds 15
    exit 1
}

Say "A iniciar a instalação inteligente do Space Desk." 'Green'

# --- Requisitos ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Pensa-E-Fecha "Erro. Precisa de executar o PowerShell como Administrador." }

# --- Configuração de Rede Segura e Agente de Navegador ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# --- RASTREADOR DINÂMICO DE URL (A MÁGICA) ---
Say "A varrer o site da Space Desk à procura do link mais recente."
$msiUrl = $null
$paginasParaVarrer = @(
    "https://www.spacedesk.net/",
    "https://www.spacedesk.net/multi-monitor-app-download/"
)

foreach ($url in $paginasParaVarrer) {
    try {
        $html = Invoke-WebRequest -Uri $url -UserAgent $UserAgent -UseBasicParsing -TimeoutSec 15 -ErrorAction SilentlyContinue
        # Expressão regular para capturar qualquer link MSI de 64 bits atualizado
        if ($html.Content -match '(https://download\.spacedesk\.net/[^"\s>]+\d+_64_v[^"\s>]+\.msi)') {
            $msiUrl = $Matches[1]
            Write-Host "[+] Link dinâmico encontrado: $msiUrl" -ForegroundColor Green
            break
        }
    } catch {}
}

# Se a varredura falhar, tenta um palpite padrão como última alternativa
if ([string]::IsNullOrEmpty($msiUrl)) {
    Write-Host "[!] Não foi possível rastrear o link automaticamente. A tentar palpite padrão..." -ForegroundColor Yellow
    $msiUrl = "https://download.spacedesk.net/current/spacedesk_driver_Win_10_64_v2130.msi"
}

# --- Preparar Downloads ---
$work = "$env:TEMP\spacedesk-deploy"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$msiPath = Join-Path $work 'spacedesk.msi'

Say "A transferir o instalador."
$downloadSucesso = $false

try {
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UserAgent $UserAgent -UseBasicParsing -TimeoutSec 90 -ErrorAction Stop
    $downloadSucesso = $true
} catch {
    Write-Host "[!] Erro no método primário de download. A tentar método secundário..." -ForegroundColor Yellow
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("user-agent", $UserAgent)
        $webClient.DownloadFile($msiUrl, $msiPath)
        $downloadSucesso = $true
    } catch {
        $downloadSucesso = $false
        $detalheErro = $_.Exception.Message
    }
}

if (-not $downloadSucesso) {
    Pensa-E-Fecha "Erro crítico. Não foi possível descarregar o instalador. Detalhe técnico: $detalheErro"
}

Say "Transferência concluída."

# --- Instalação Silenciosa ---
Say "A instalar o controlador de vídeo virtual. Aguarde."
$Arguments = "/i `"$msiPath`" /qn /norestart"
$Process = Start-Process msiexec.exe -ArgumentList $Arguments -Wait -PassThru

if ($Process.ExitCode -ne 0) {
    Pensa-E-Fecha "Erro interno na instalação. Código de erro da MSI: $($Process.ExitCode)"
}
Say "Instalação concluída com sucesso."

# --- Configuração e Ativação do Serviço ---
$serviceName = "spacedeskService"
Set-Service -Name $serviceName -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name $serviceName -ErrorAction SilentlyContinue

# --- Captura de IPs para Conexão ---
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
        Say "Ligue o cabo e ligue a ancoragem no seu dispositivo. Conecte usando os endereços:"
        for ($i = 1; $i -le 2; $i++) {
            foreach ($ip in $ips) { Speak-IPAddress -Label "IP" -Value $ip }
            Start-Sleep -Seconds 2
        }
    } else {
        Say "Aviso. Nenhum endereço de rede detetado. Verifique a ligação por cabo."
    }
}
