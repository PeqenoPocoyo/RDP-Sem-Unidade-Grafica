# ============================================================
# Install-Spacedesk-Headless.ps1
# Instala o driver do SpaceDesk silenciosamente, garante que o
# serviço de tela virtual está rodando e dita os IPs locais por voz.
# Ideal para transformar celulares/notebooks em monitores via USB às cegas.
#
# Uso (PowerShell como Administrador):
#   irm https://SEU_HOST/Install-Spacedesk-Headless.ps1 | iex
# ============================================================

if (-not (Test-Path variable:Mute)) { $Mute = $false }

# --- TTS: Inicialização idêntica ao seu script original ---
$Global:ttsVoice = $null
$Global:ttsOk = $false
if (-not $Mute) {
    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        $Global:ttsVoice = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $vozesInstaladas = $Global:ttsVoice.GetInstalledVoices() | Where-Object { $_.Enabled }
        if ($vozesInstaladas.Count -gt 0) {
            try { $Global:ttsVoice.SelectVoiceByHints('NotSet', 'NotSet', 0, [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')) } catch {}
            $Global:ttsVoice.Rate = -2 # Um pouco mais rápido que o seu (-4), mas legível para IPs
            $Global:ttsOk = $true
        }
    } catch { $Global:ttsOk = $false }
}

# --- Função adaptada para ditar IPs (Soletrando números e "ponto") ---
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
    } catch {
        Write-Host "Erro ao ditar IP por voz: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Say {
    param([string]$Text, [string]$Color = 'Cyan')
    Write-Host $Text -ForegroundColor $Color
    if ($Global:ttsOk) {
        try { $Global:ttsVoice.Speak($Text) } catch {}
    }
}

Say "Iniciando verificação de requisitos para o Space Desk." 'Green'

# --- Requisito 1: Elevação ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Say "Erro. Este terminal não está como administrador. Abra o PowerShell como administrador." 'Red'
    exit 1
}
Say "Permissão de administrador confirmada."

# --- Requisito 2: Versão do PowerShell ---
$psMajor = $PSVersionTable.PSVersion.Major
if ($psMajor -lt 3) {
    Say "Erro. Versão do PowerShell muito antiga. Mínima necessária é a versão três." 'Red'
    exit 1
}

# --- Requisito 3: Conectividade ---
Say "Testando conexão com a internet."
$netOk = $false
try {
    $testResp = Invoke-WebRequest -Uri 'https://www.spacedesk.net' -UseBasicParsing -TimeoutSec 10
    if ($testResp.StatusCode -ge 200 -and $testResp.StatusCode -lt 400) { $netOk = $true }
} catch { $netOk = $false }

if (-not $netOk) {
    Say "Aviso. Não consegui confirmar acesso ao site do Space Desk. O download pode falhar." 'Yellow'
}

# --- Pasta de trabalho e Download ---
$work = "$env:TEMP\spacedesk-deploy"
New-Item -ItemType Directory -Force -Path $work | Out-Null

# Link direto para a versão estável de 64-bits (pode ser atualizado se necessário)
$msiUrl = "https://download.spacedesk.net/current/spacedesk_driver_Win_10_64_v2130.msi"
$msiPath = Join-Path $work 'spacedesk.msi'

Say "Baixando instalador do monitor virtual."
try {
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing -TimeoutSec 120
} catch {
    Say "Erro ao baixar o instalador do Space Desk." 'Red'
    exit 1
}
Say "Download concluído."

# --- Instalação Silenciosa ---
Say "Instalando driver de vídeo virtual do Space Desk. Por favor, aguarde."
# /qn = totalmente silencioso, /norestart = evita reinicializações inesperadas
$Arguments = "/i `"$msiPath`" /qn /norestart"
$Process = Start-Process msiexec.exe -ArgumentList $Arguments -Wait -PassThru

if ($Process.ExitCode -ne 0) {
    Say "Erro na instalação do Space Desk. Código de erro $($Process.ExitCode)" 'Red'
    exit 1
}
Say "Instalação do driver concluída com sucesso."

# --- Inicialização e Configuração do Serviço ---
Say "Configurando serviço de rede de vídeo."
$serviceName = "spacedeskService"

Set-Service -Name $serviceName -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name $serviceName -ErrorAction SilentlyContinue

$svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Say "O serviço do Space Desk está ativo e aguardando conexões." 'Green'
} else {
    Say "Aviso. Não consegui confirmar se o serviço inicializou corretamente." 'Yellow'
}

# --- Limpeza ---
Remove-Item $msiPath -ErrorAction SilentlyContinue

# --- Captura de IPs (foco na Ancoragem USB) ---
# Coleta IPs válidos descartando interfaces locais virtuais ou IPs de autoconfiguração (169.254)
$ips = @()
try {
    $ips = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -notlike '169.254.*' -and $_.ToString() -ne '127.0.0.1' } |
        ForEach-Object { $_.ToString() }
} catch {}

# --- Output Visual Final ---
Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  SpaceDesk Instalado (Modo Headless Ativo)      " -ForegroundColor Green
Write-Host "================================================"
Write-Host " Computador : $env:COMPUTERNAME"
Write-Host " IP(s)      : $($ips -join ', ')"
Write-Host "================================================"
Write-Host "DICA: Ative a Ancoragem USB no celular para criar a rede direta."
Write-Host "================================================"

# --- Narração Final dos IPs encontrados ---
if ($Global:ttsOk) {
    Say "Pronto! O monitor virtual está ativo no computador $env:COMPUTERNAME."
    Say "Ligue a ancoragem USB no seu celular e abra o aplicativo do Space Desk."
    
    if ($ips.Count -gt 0) {
        Say "Conecte usando um dos seguintes endereços de I Pê listados a seguir:"
        # Repete a lista de IPs duas vezes para dar tempo de anotar/digitar
        for ($i = 1; $i -le 2; $i++) {
            foreach ($ip in $ips) {
                Speak-IPAddress -Label "Endereço" -Value $ip
            }
            Start-Sleep -Seconds 2
        }
    } else {
        Say "Aviso. Nenhum endereço de I Pê ativo foi detectado. Verifique o cabo USB."
    }
}