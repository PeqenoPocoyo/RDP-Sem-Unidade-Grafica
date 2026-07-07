# ============================================================
# Install-Spacedesk-Direct.ps1
# Versão ultra-limpa usando o link de redirecionamento direto.
# Instala e dita os IPs em modo headless.
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
    Write-Host "`n[!] Fechando em 15 segundos para permitir a leitura do erro..." -ForegroundColor Yellow
    Start-Sleep -Seconds 15
    exit 1
}

Say "Iniciando a instalação direta do Space Desk." 'Green'

# --- Requisitos ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Pensa-E-Fecha "Erro. Precisa executar o PowerShell como Administrador." }

# --- Configuração de Rede e URL Direta ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# A sua URL mágica que substitui todo o Web Scraping:
$msiUrl = "https://www.spacedesk.net/downloadidd64"

$work = "$env:TEMP\spacedesk-deploy"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$msiPath = Join-Path $work 'spacedesk.msi'

Say "Baixando o instalador através do link de redirecionamento."
$downloadSucesso = $false

try {
    # O Invoke-WebRequest vai seguir o redirecionamento da sua URL até o arquivo .msi real
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UserAgent $UserAgent -UseBasicParsing -TimeoutSec 90 -ErrorAction Stop
    $downloadSucesso = $true
} catch {
    Write-Host "[!] Erro no método primário. Tentando fallback via .NET..." -ForegroundColor Yellow
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
    Pensa-E-Fecha "Erro crítico. Não foi possível baixar o instalador. Detalhe: $detalheErro"
}

Say "Download concluído."

# --- Instalação Silenciosa ---
Say "Instalando o driver de vídeo virtual. Por favor, aguarde."
$Arguments = "/i `"$msiPath`" /qn /norestart"
$Process = Start-Process msiexec.exe -ArgumentList $Arguments -Wait -PassThru

if ($Process.ExitCode -ne 0) {
    Pensa-E-Fecha "Erro na instalação. Código de erro da MSI: $($Process.ExitCode)"
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
        Say "Conecte o dispositivo e use um dos seguintes endereços:"
        for ($i = 1; $i -le 2; $i++) {
            foreach ($ip in $ips) { Speak-IPAddress -Label "IP" -Value $ip }
            Start-Sleep -Seconds 2
        }
    } else {
        Say "Aviso. Nenhum endereço de rede detectado. Verifique os cabos ou conexões."
    }
}
