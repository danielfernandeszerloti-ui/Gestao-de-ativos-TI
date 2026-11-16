<#
    Coletor de inventário do domínio -> Gestão de Ativos (Grupo Zerbini)
    ---------------------------------------------------------------------
    Lê os computadores do Active Directory, roda o mesmo "Inventário em lote"
    da Central de Diagnóstico (16 máquinas em paralelo, WinRM ou WMI/DCOM)
    e envia o resultado para a Gestão de Ativos (ativos.grupozerbini.com.br).
    A Gestão atualiza sozinha os campos técnicos dos ativos ligados e lista
    as máquinas do domínio que ainda não têm cadastro.

    SOMENTE CONSULTA nas estações. Não envia senhas nem chaves do BitLocker
    (só o status: Ativo, Suspenso, Não criptografado).

    Uso:
      .\Enviar-InventarioGestao.ps1 -Instalar      configura a chave e cria a tarefa agendada
      .\Enviar-InventarioGestao.ps1                coleta e envia agora (é o que a tarefa roda)
      .\Enviar-InventarioGestao.ps1 -Lista maquinas.txt   só as máquinas da lista
      .\Enviar-InventarioGestao.ps1 -Teste         coleta sem enviar e mostra o resumo

    Requisitos: Windows PowerShell 5.1, conta com admin nas estações (a mesma
    usada na Central de Diagnóstico) e acesso HTTPS a *.supabase.co.
#>
[CmdletBinding()]
param(
    [switch]$Instalar,
    [switch]$Teste,
    [string]$Lista,
    [int]$DiasSemLogon = 90,
    [int]$Paralelo = 16
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Endereço e chave pública da Gestão de Ativos (a chave pública é feita para ficar em clientes;
# quem autoriza o envio é a CHAVE DO COLETOR, gerada na tela Domínio e guardada criptografada nesta máquina)
$SupabaseUrl = 'https://gybdgrfklukgrsfomrey.supabase.co'
$SupabaseKey = 'sb_publishable_gNqnWw9w3gPL9ZaUQJiSvA_DqgjmDak'

$Pasta     = Join-Path $env:ProgramData 'ColetorGestao'
$ArqConfig = Join-Path $Pasta 'config.json'
$PastaLog  = Join-Path $Pasta 'logs'
$NomeTarefa = 'Coletor de inventário - Gestão de Ativos'

function Log([string]$Msg, [string]$Cor = 'Gray') {
    $linha = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    Write-Host $linha -ForegroundColor $Cor
    try {
        New-Item -ItemType Directory -Path $PastaLog -Force | Out-Null
        Add-Content -Path (Join-Path $PastaLog ("coletor_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))) -Value $linha -Encoding UTF8
    } catch {}
}

# A chave fica criptografada com DPAPI no escopo da máquina e o arquivo só é legível por Administradores e SYSTEM
Add-Type -AssemblyName System.Security
function Protect-Texto([string]$t) {
    [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($t), $null, 'LocalMachine'))
}
function Unprotect-Texto([string]$b) {
    [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($b), $null, 'LocalMachine'))
}
function Restringir-Pasta([string]$p, [string]$contaTarefa) {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $heranca = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $ids = @((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'), (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'))
    if ($contaTarefa) { try { $ids += (New-Object Security.Principal.NTAccount $contaTarefa).Translate([Security.Principal.SecurityIdentifier]) } catch {} }
    foreach ($id in $ids) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id, 'FullControl', $heranca, 'None', 'Allow')))
    }
    Set-Acl -Path $p -AclObject $acl
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- Computadores do domínio (sem RSAT) ----------
function Get-ComputadoresAD([int]$Dias) {
    $limite = (Get-Date).AddDays(-$Dias).ToFileTimeUtc()
    $filtro = "(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2))(operatingSystem=Windows*)(!(operatingSystem=*Server*))(lastLogonTimestamp>=$limite))"
    $ds = New-Object DirectoryServices.DirectorySearcher([ADSI]'', $filtro, @('name'))
    $ds.PageSize = 500
    @($ds.FindAll() | ForEach-Object { "$($_.Properties['name'])" } | Where-Object { $_ } | Sort-Object -Unique)
}

# =====================================================================
#  Funções do inventário em lote - iguais às da Central de Diagnóstico
# =====================================================================
$CodigoInventario = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$HKLM = [uint32]2147483650
$global:Protocolo = '-'

function Fmt-Data($d, [string]$Vazio = '-') { if ($d) { ([datetime]$d).ToString('dd/MM/yyyy HH:mm') } else { $Vazio } }

function Test-IsLocal([string]$Computer) {
    $c = $Computer.Trim().ToLower()
    $c -in @('', '.', 'localhost', '127.0.0.1') -or
    $c -eq $env:COMPUTERNAME.ToLower() -or
    $c -like "$($env:COMPUTERNAME.ToLower()).*"
}

function Test-Porta([string]$Alvo, [int]$Porta, [int]$Ms = 1500) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try   { $tcp.ConnectAsync($Alvo, $Porta).Wait($Ms) -and $tcp.Connected }
    catch { $false }
    finally { $tcp.Close() }
}

function New-OpcaoDcom {
    try {
        $o = New-Object Microsoft.Management.Infrastructure.Options.DComSessionOptions
        $o.PacketPrivacy   = $true
        $o.PacketIntegrity = $true
        $o.Impersonation   = [Microsoft.Management.Infrastructure.Options.ImpersonationType]::Impersonate
        return $o
    } catch { return (New-CimSessionOption -Protocol Dcom) }
}

function Get-Cim([string]$Computer) {
    if (Test-IsLocal $Computer) {
        $global:Protocolo = 'local'
        return New-CimSession -SessionOption (New-OpcaoDcom) -OperationTimeoutSec 60
    }
    $erroWinRM = 'porta 5985 fechada'
    if (Test-Porta $Computer 5985) {
        try {
            $s = New-CimSession -ComputerName $Computer -OperationTimeoutSec 60 -ErrorAction Stop
            $global:Protocolo = 'WinRM'
            return $s
        } catch { $erroWinRM = $_.Exception.Message }
    }
    try {
        $s = New-CimSession -ComputerName $Computer -SessionOption (New-OpcaoDcom) -OperationTimeoutSec 60 -ErrorAction Stop
        $global:Protocolo = 'DCOM'
        return $s
    } catch {
        throw "Não foi possível conectar em '$Computer' (WinRM: $erroWinRM | DCOM: $($_.Exception.Message)). Verifique se a máquina está ligada e na rede (botão Rede)."
    }
}

function Get-RegValue($Session, [string]$Key, [string]$Name) {
    $r = Invoke-CimMethod -CimSession $Session -Namespace root/cimv2 -ClassName StdRegProv -MethodName GetStringValue `
         -Arguments @{ hDefKey = $HKLM; sSubKeyName = $Key; sValueName = $Name }
    if ($r.ReturnValue -eq 0) { $r.sValue }
}

function Get-BLTexto($v) {
    if (-not $v) { return 'n/d' }
    if ([int]$v.ConversionStatus -eq 0) { return 'Não criptografado' }
    if ([int]$v.ConversionStatus -eq 1 -and [int]$v.ProtectionStatus -eq 0) { return 'SUSPENSO' }
    if ([int]$v.ConversionStatus -eq 1) { return 'Ativo' }
    'Em andamento'
}

function Get-InvResumo([string]$Computer) {
    $r = [ordered]@{ Computador = $Computer; Status = ''; Conexão = ''; 'Usuário logado' = ''; Fabricante = ''; Modelo = ''
                     'Nº série' = ''; Patrimônio = ''; Tipo = ''; CPU = ''; 'RAM (GB)' = ''; 'Disco C (GB)' = ''; 'C livre (GB)' = ''
                     'Tipo disco' = ''; Windows = ''; Versão = ''; Build = ''; 'Windows instalado' = ''; 'Último boot' = ''
                     'Uptime (dias)' = ''; IP = ''; MAC = ''; Domínio = ''; BIOS = ''; 'BitLocker C:' = ''; Detalhe = '' }
    if (-not (Test-IsLocal $Computer) -and -not (Test-Porta $Computer 5985 1000) -and -not (Test-Porta $Computer 135 1000)) {
        $r.Status = 'Offline'; $r.Detalhe = 'Sem resposta (desligada, fora da rede ou nome inexistente)'
        return [pscustomobject]$r
    }
    try { $s = Get-Cim $Computer } catch { $r.Status = 'Erro'; $r.Detalhe = $_.Exception.Message; return [pscustomobject]$r }
    try {
        $r.Conexão = $global:Protocolo
        $cs   = Get-CimInstance -CimSession $s -ClassName Win32_ComputerSystem
        $csp  = Get-CimInstance -CimSession $s -ClassName Win32_ComputerSystemProduct
        $bios = Get-CimInstance -CimSession $s -ClassName Win32_BIOS
        $enc  = Get-CimInstance -CimSession $s -ClassName Win32_SystemEnclosure | Select-Object -First 1
        $os   = Get-CimInstance -CimSession $s -ClassName Win32_OperatingSystem
        $cpu  = Get-CimInstance -CimSession $s -ClassName Win32_Processor | Select-Object -First 1
        $chassis = @{ 3='Desktop'; 4='Desktop'; 6='Mini torre'; 7='Torre'; 8='Portátil'; 9='Notebook'; 10='Notebook'; 13='All-in-One';
                      14='Notebook'; 30='Tablet'; 31='Conversível'; 32='Destacável'; 35='Mini PC'; 36='Stick PC' }
        $r.Computador       = $cs.Name
        $r.'Usuário logado' = $cs.UserName
        $r.Fabricante       = $cs.Manufacturer
        $r.Modelo           = if ($cs.Manufacturer -match 'LENOVO' -and $csp.Version) { "$($csp.Version) ($($cs.Model))" } else { $cs.Model }
        $r.'Nº série'       = $bios.SerialNumber
        $r.Patrimônio       = $enc.SMBIOSAssetTag
        $r.Tipo             = ($enc.ChassisTypes | ForEach-Object { $chassis[[int]$_] } | Where-Object { $_ } | Select-Object -First 1)
        $r.CPU              = "$($cpu.Name)".Trim()
        $r.'RAM (GB)'       = [math]::Round($cs.TotalPhysicalMemory / 1GB, 0)
        $c = Get-CimInstance -CimSession $s -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
        if ($c) { $r.'Disco C (GB)' = [math]::Round($c.Size / 1GB, 0); $r.'C livre (GB)' = [math]::Round($c.FreeSpace / 1GB, 1) }
        try {
            $mt = @{ 3 = 'HDD'; 4 = 'SSD' }
            $r.'Tipo disco' = (@(Get-CimInstance -CimSession $s -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_PhysicalDisk |
                               Where-Object { [int]$_.BusType -ne 7 } | ForEach-Object { $t = $mt[[int]$_.MediaType]; if (-not $t) { $t = '?' }; if ([int]$_.BusType -eq 17) { "$t NVMe" } else { $t } }) -join ', ')
        } catch {}
        $r.Windows             = $os.Caption -replace '^Microsoft\s+', ''
        $r.Versão              = try { Get-RegValue $s 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion' } catch { '' }
        $r.Build               = $os.BuildNumber
        $r.'Windows instalado' = if ($os.InstallDate) { $os.InstallDate.ToString('dd/MM/yyyy') }
        $r.'Último boot'       = Fmt-Data $os.LastBootUpTime
        $r.'Uptime (dias)'     = [int][math]::Floor(((Get-Date) - $os.LastBootUpTime).TotalDays)
        $net = Get-CimInstance -CimSession $s -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' |
               Sort-Object { -not $_.DefaultIPGateway } | Select-Object -First 1
        if ($net) { $r.IP = ($net.IPAddress | Where-Object { $_ -match '^\d+\.' }) -join ', '; $r.MAC = $net.MACAddress }
        $r.Domínio = $cs.Domain
        $r.BIOS    = $bios.SMBIOSBIOSVersion
        try {
            $bl = Get-CimInstance -CimSession $s -Namespace root/cimv2/Security/MicrosoftVolumeEncryption -ClassName Win32_EncryptableVolume -Filter "DriveLetter='C:'"
            $r.'BitLocker C:' = Get-BLTexto $bl
        } catch { $r.'BitLocker C:' = 'n/d' }
        $r.Status = 'Online'
    } catch { $r.Status = 'Parcial'; $r.Detalhe = $_.Exception.Message }
    finally { Remove-CimSession $s -ErrorAction SilentlyContinue }
    [pscustomobject]$r
}
'@

function Invoke-InventarioLote([string[]]$Maquinas, [int]$Max) {
    $pool = [runspacefactory]::CreateRunspacePool(1, $Max); $pool.Open()
    $res  = New-Object System.Collections.Generic.List[object]
    $pend = New-Object System.Collections.ArrayList
    try {
        foreach ($m in $Maquinas) {
            $ps = [powershell]::Create(); $ps.RunspacePool = $pool
            [void]$ps.AddScript($CodigoInventario + "`nGet-InvResumo -Computer '$m'")
            [void]$pend.Add(@{ PS = $ps; H = $ps.BeginInvoke(); Nome = $m })
        }
        $ultimo = Get-Date
        while ($pend.Count) {
            foreach ($j in @($pend)) {
                if (-not $j.H.IsCompleted) { continue }
                try {
                    $o = @($j.PS.EndInvoke($j.H))
                    if ($o.Count) { $res.Add($o[0]) } else { $res.Add([pscustomobject]@{ Computador = $j.Nome; Status = 'Erro'; Detalhe = 'Sem retorno' }) }
                } catch { $res.Add([pscustomobject]@{ Computador = $j.Nome; Status = 'Erro'; Detalhe = $_.Exception.Message }) }
                $j.PS.Dispose(); $pend.Remove($j)
            }
            if (((Get-Date) - $ultimo).TotalSeconds -ge 30) { Log "$($res.Count) de $($Maquinas.Count) máquinas concluídas..."; $ultimo = Get-Date }
            Start-Sleep -Milliseconds 300
        }
    } finally {
        foreach ($j in $pend) { try { $j.PS.Stop(); $j.PS.Dispose() } catch {} }
        $pool.Close(); $pool.Dispose()
    }
    $res
}

function Enviar([string]$Chave, [object[]]$Resultados) {
    # Campos texto: o banco recebe exatamente as colunas do inventário em lote
    $lista = @($Resultados | ForEach-Object {
        $h = [ordered]@{}
        foreach ($p in $_.PSObject.Properties) { $h[$p.Name] = if ($null -eq $p.Value) { '' } else { "$($p.Value)" } }
        $h
    })
    $corpo = @{ p_chave = $Chave; p_maquinas = $lista; p_origem = $env:COMPUTERNAME } | ConvertTo-Json -Depth 5 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($corpo)
    $hdr = @{ apikey = $SupabaseKey; Authorization = "Bearer $SupabaseKey" }
    $tentativa = 0
    while ($true) {
        try {
            return Invoke-RestMethod -Method Post -Uri "$SupabaseUrl/rest/v1/rpc/dominio_receber" -Headers $hdr `
                   -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 120
        } catch {
            $tentativa++
            $msg = $_.Exception.Message
            try { $msg = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
            if ($msg -match 'Chave do coletor' -or $tentativa -ge 3) { throw "Envio recusado: $msg" }
            Log "Falha no envio ($msg). Nova tentativa em 30 s..." 'Yellow'
            Start-Sleep -Seconds 30
        }
    }
}

# =====================================================================
#  INSTALAÇÃO
# =====================================================================
if ($Instalar) {
    if (-not (Test-Admin)) { throw 'Execute a instalação como administrador (botão direito no PowerShell > Executar como administrador).' }
    Write-Host ''
    Write-Host 'Instalação do coletor de inventário' -ForegroundColor Cyan
    Write-Host '1) Na Gestão de Ativos, abra Ferramentas > Domínio > "Gerar chave do coletor" e copie a chave.'
    $seg = Read-Host '   Cole a chave do coletor' -AsSecureString
    $chave = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($seg))
    if ($chave.Length -lt 32) { throw 'A chave parece incompleta. Gere outra na tela Domínio e cole inteira.' }

    $hora = Read-Host '2) Horário diário da coleta [07:30]'
    if (-not $hora) { $hora = '07:30' }
    if ($hora -notmatch '^\d{1,2}:\d{2}$') { throw 'Horário inválido. Use HH:MM, por exemplo 07:30.' }

    Write-Host '3) Conta que vai rodar a tarefa: a mesma conta de suporte com admin nas estações (ex.: ZERBINI\suporte.ti).'
    $cred = Get-Credential -Message 'Conta de domínio com permissão de admin nas estações'
    if (-not $cred) { throw 'Instalação cancelada.' }

    New-Item -ItemType Directory -Path $Pasta -Force | Out-Null
    $destino = Join-Path $Pasta 'Enviar-InventarioGestao.ps1'
    if ($PSCommandPath -ne $destino) { Copy-Item -Path $PSCommandPath -Destination $destino -Force }
    @{ chave = (Protect-Texto $chave); hora = $hora; criado_em = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content -Path $ArqConfig -Encoding UTF8
    Restringir-Pasta $Pasta $cred.UserName

    Log 'Testando a chave com um envio vazio...'
    $r = Enviar $chave @()
    Log 'Chave aceita pela Gestão de Ativos.' 'Green'

    $acao = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$destino`""
    $gatilho = New-ScheduledTaskTrigger -Daily -At $hora
    $opc = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $NomeTarefa -Action $acao -Trigger $gatilho -Settings $opc -RunLevel Highest `
        -User $cred.UserName -Password $cred.GetNetworkCredential().Password -Description 'Envia o inventário dos computadores do domínio para a Gestão de Ativos' -Force | Out-Null
    Log "Tarefa agendada criada: '$NomeTarefa', todo dia às $hora, com a conta $($cred.UserName)." 'Green'

    $agora = Read-Host 'Rodar a primeira coleta agora? (S/N) [S]'
    if ($agora -notmatch '^[Nn]') { Start-ScheduledTask -TaskName $NomeTarefa; Log "Coleta iniciada em segundo plano. Acompanhe em $PastaLog ou na tela Domínio da Gestão de Ativos." 'Green' }
    return
}

# =====================================================================
#  COLETA E ENVIO
# =====================================================================
try {
    $inicio = Get-Date
    if (-not $Teste) {
        if (-not (Test-Path $ArqConfig)) { throw "Coletor não configurado. Rode: .\Enviar-InventarioGestao.ps1 -Instalar" }
        $chave = Unprotect-Texto ((Get-Content $ArqConfig -Raw | ConvertFrom-Json).chave)
    }
    $maquinas = if ($Lista) {
        @(Get-Content $Lista | ForEach-Object { $_ -split '[\s,;]+' } | Where-Object { $_ -match '^[A-Za-z0-9][A-Za-z0-9._-]*$' } | Sort-Object -Unique)
    } else { Get-ComputadoresAD $DiasSemLogon }
    if (-not $maquinas.Count) { throw 'Nenhum computador encontrado.' }
    Log "Coletando $($maquinas.Count) computador(es) (logon nos últimos $DiasSemLogon dias)..." 'Cyan'

    $res = @(Invoke-InventarioLote $maquinas $Paralelo)
    $on  = @($res | Where-Object { $_.Status -eq 'Online' }).Count
    $off = @($res | Where-Object { $_.Status -eq 'Offline' }).Count
    Log "Coleta concluída em $([int]((Get-Date) - $inicio).TotalMinutes) min: $on online, $off offline, $($res.Count - $on - $off) com erro."

    if ($Teste) {
        $res | Sort-Object Computador | Select-Object Computador, Status, Modelo, 'Nº série', Windows, 'Usuário logado', 'BitLocker C:' | Format-Table -AutoSize
        return
    }
    $r = Enviar $chave $res
    Log ("Enviado para a Gestão de Ativos: {0} computadores, {1} ligados a ativos, {2} cadastros atualizados, {3} novos no domínio." -f $r.total, $r.ligados, $r.atualizados, $r.novos) 'Green'

    Get-ChildItem $PastaLog -Filter 'coletor_*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force -ErrorAction SilentlyContinue
} catch {
    Log "ERRO: $($_.Exception.Message)" 'Red'
    exit 1
}
