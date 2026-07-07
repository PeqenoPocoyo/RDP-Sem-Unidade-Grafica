# ============================================================
# Install-Spacedesk-CleanInstall.ps1
# Toda vez que é executado, remove completamente a versão anterior,
# limpa registros/pastas, e reinstala do zero com o link direto.
# Perfeito para rodar no modo headless (às cegas).
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
    Write-Host "`n[!] Fechando em 15 segundos..." -ForegroundColor Yellow
    Start-Sleep -Seconds 15
    exit 1
}

Say "Iniciando o assistente de instalação limpa do Space Desk." 'Green'

# --- Requisitos ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Pensa-E-Fecha "Erro. Precisa executar o PowerShell como Administrador." }

# --- Configuração de Rede ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
$msiUrl = "https://www.spacedesk.net/downloadidd64"
$work = "$env:TEMP\spacedesk-deploy"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$msiPath = Join-Path $work 'spacedesk.msi'


# ============================================================
#  PASSO 1: DESINSTALAÇÃO TOTAL E PURGA DE CONFIGURAÇÕES
# ============================================================
Say "Verificando se existem versões anteriores para remoção total." 'Yellow'

# 1.1 Parar o serviço se ele estiver rodando
if (Get-Service -Name "spacedeskService" -ErrorAction SilentlyContinue) {
    Say "Parando o serviço ativo do Space Desk."
    Stop-Service -Name "spacedeskService" -Force -ErrorAction SilentlyContinue
}

# 1.2 Fechar processos residuais em segundo plano (Console de controle, tray bar, etc)
$processos = @("spacedeskService", "spacedeskConsole", "spacedeskTraybar", "spacedeskDriver")
foreach ($proc in $processos) {
    if (Get-Process -Name $proc -ErrorAction SilentlyContinue) {
        Stop-Process -Name $proc -Force -ErrorAction SilentlyContinue
    }
}

# 1.3 Procurar o ID de desinstalação nativo (ProductCode) no Registro do Windows
$regPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)
foreach ($path in $regPaths) {
    if (Test-Path $path) {
        Get-ChildItem -Path $path | ForEach-Object {
            $displayName = $_.GetValue("DisplayName")
            if ($displayName -like "*spacedesk*") {
                # Se achou o instalador baseado em MSI, pega o GUID de desinstalação
                $uninstallString = $_.GetValue("UninstallString")
                if ($uninstallString -match '\{[A-F0-9-]+\}') {
                    $productCode = $Matches[0]
                    Say "Removendo o software antigo de forma silenciosa." 'Yellow'
                    $uninst = Start-Process msiexec.exe -ArgumentList "/x $productCode /qn /norestart" -Wait -PassThru -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

# 1.4 LIMPEZA DA "ALMA": Apaga configurações antigas e caminhos órfãos
Say "Limpando arquivos temporários e chaves de registro residuais."
Remove-Item -Path "C:\Program Files\spacedesk" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "C:\Program Files (x86)\spacedesk" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "HKLM:\SOFTWARE\spacedesk" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "HKCU:\SOFTWARE\spacedesk" -Recurse -Force -ErrorAction SilentlyContinue

# Pequena pausa para garantir que o Windows liberou os arquivos do sistema antes da reinstalação
Start-Sleep -Seconds 3
Say "O sistema está completamente limpo. Iniciando nova instalação." 'Green'


# ============================================================
#  PASSO 2: DOWNLOAD DA VERSÃO MAIS RECENTE
# ============================================================
Say "Baixando o novo instalador atualizado."
$downloadSucesso = $false

try {
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UserAgent $UserAgent -UseBasicParsing -TimeoutSec 90 -ErrorAction Stop
    $downloadSucesso = $true
} catch {
    Write-Host "[!] Falha no download primário. Tentando método alternativo .NET..." -ForegroundColor Yellow
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


# ============================================================
#  PASSO 3: INSTALAÇÃO DO ZERO
# ============================================================
Say "Instalando o driver de vídeo virtual do zero. Por favor, aguarde."
$Arguments = "/i `"$msiPath`" /qn /norestart"
$Process = Start-Process msiexec.exe -ArgumentList $Arguments -Wait -PassThru

if ($Process.ExitCode -ne 0) {
    Pensa-E-Fecha "Erro na instalação limpa. Código de erro da MSI: $($Process.ExitCode)"
}
Say "Instalação concluída com sucesso."


# ============================================================
#  PASSO 4: ATIVAÇÃO E ANÚNCIO DOS IPS
# ============================================================
$serviceName = "spacedeskService"
Set-Service -Name $serviceName -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name $serviceName -ErrorAction SilentlyContinue

# Coleta de IPs válidos para ditar
$ips = @()
try {
    $ips = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -notlike '169.254.*' -and $_.ToString() -ne '127.0.0.1' } |
        ForEach-Object { $_.ToString() }
} catch {}

Remove-Item $msiPath -ErrorAction SilentlyContinue

if ($Global:ttsOk) {
    Say "O monitor virtual limpo está pronto no computador $env:COMPUTERNAME."
    if ($ips.Count -gt 0) {
        Say "Conecte seu aparelho e digite um dos seguintes endereços:"
        for ($i = 1; $i -le 2; $i++) {
            foreach ($ip in $ips) { Speak-IPAddress -Label "IP" -Value $ip }
            Start-Sleep -Seconds 2
        }
    } else {
        Say "Aviso. Nenhum endereço de rede detectado. Conecte o cabo USB ou Wi-Fi."
    }
}
