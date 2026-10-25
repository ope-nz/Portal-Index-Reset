#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Give Portal for ArcGIS 12.x an EMPTY search index that boots (embedded OpenSearch 2.x),
    so a Full Reindex can then be run from the Portal Admin UI.

.DESCRIPTION
    The Portal index lives in <dir.index> (default C:\arcgisportal\index):

        config\                 opensearch.yml, jvm.options, keystore, certs\, opensearch-security\*.yml
        elastic.options         Portal's encrypted copy of the index credentials
        nodes\0\                the OpenSearch cluster: cluster state (_state) + every index (indices\)

    Everything under nodes\ is derived data. ago-items / ago-users / ago-groups are created and filled
    by a Full Reindex (Portal does not create them at startup); .opendistro_security is rebuilt from
    config\opensearch-security\*.yml on first start
    (plugins.security.allow_default_init_securityindex: true); the small esri-ds-* / .dsconfig indices
    were created by the ArcGIS Data Store runtime at original cluster creation and are not recreated
    after a reset (Portal runs without them).

    Actions (least destructive first):

      Diagnose          Read-only health report (service, zombie java, locks, certs, DNS, disk, cluster
                        health, indices/shards, log tails). Writes a report folder.
      SaveGoldenConfig  Copy config\ + elastic.options from a HEALTHY machine to a safe place.
                        Do this now, while it works. It is the template for a later reset.
      ResetCluster      OFFLINE. Stop Portal, move nodes\ aside (keeps config + certs), start Portal.
                        OpenSearch forms a fresh empty cluster. Optional -FromGolden also replaces
                        config\ with the golden copy (use when certs/yml look damaged).
      RebuildConfig     OFFLINE, no golden copy needed. Regenerates config\ in place: new CA / node /
                        admin certificates made with the bundled openssl exactly as Portal makes them,
                        opensearch.yml rebuilt from the known layout (same cluster name and ports),
                        jvm.options / log4j2.properties / security yml from Esri's templates. The two
                        credential files that cannot be regenerated, elastic.options and
                        opensearch-security\internal_users.yml, are carried over unchanged and must be
                        intact. Add -WithResetCluster to also move nodes\ aside in the same run.
                        (Portal itself does NOT rebuild a missing index directory: proven 24 Oct 2026,
                        and Portal Admin's Reconfigure does not either.)
      Rollback          Stop Portal and put a chosen backup back.

    !!! KEEP elastic.options AT ALL COSTS !!!
    <index>\elastic.options is the ONE file nothing can rebuild: Portal does not recreate it (verified),
    Reconfigure does not, this script cannot, another Portal's copy is useless (different key), and a full
    scan of the machine including Portal's Postgres data found no second copy. Run SaveGoldenConfig today,
    schedule it daily, keep the golden folder off the machine.

    Nothing is ever deleted: data is MOVED into <BackupRoot>\<timestamp>_<Action>\.
    After a successful reset: Portal Admin UI > System > Indexer > Reindex (Full).

.PARAMETER Action
    Diagnose | SaveGoldenConfig | ResetCluster | RebuildConfig | Rollback

.PARAMETER InstallDir
    Portal install directory. Default: the AGSPORTAL environment variable set by the Portal installer
    (process, then machine scope), falling back to C:\ArcGIS\Portal.

.PARAMETER IndexDir
    Index directory. Default: dir.index from portal-config.properties, looked up in <InstallDir>\framework\etc,
    then <InstallDir>\etc, then the content-store copy under dir.data\content\items\portal.

.PARAMETER BackupRoot
    Where moved-aside data and reports go. Default <parent of IndexDir>\index_backups.

.PARAMETER GoldenDir
    Where SaveGoldenConfig stores / ResetCluster -FromGolden reads the known-good config.
    Default <BackupRoot>\golden_config.

.PARAMETER FromGolden
    ResetCluster only: also replace config\ and elastic.options from GoldenDir.

.PARAMETER WithResetCluster
    RebuildConfig only: also move nodes\ aside so the rebuilt config starts an empty cluster.

.PARAMETER LabNoService
    Testing only, on a machine without Portal: skip all service control and the boot wait, just
    perform the file operations and report. Never use on a real Portal machine.

.PARAMETER BackupName
    Rollback only: folder name inside BackupRoot to restore.

.PARAMETER WaitMinutes
    How long to wait for OpenSearch after starting Portal. Default 20.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\Reset-PortalIndex.ps1 -Action Diagnose
.EXAMPLE
    .\Reset-PortalIndex.ps1 -Action SaveGoldenConfig          # on a healthy day
.EXAMPLE
    .\Reset-PortalIndex.ps1 -Action ResetCluster              # index corrupt, config fine
.EXAMPLE
    .\Reset-PortalIndex.ps1 -Action ResetCluster -FromGolden  # certs/config also suspect, golden copy exists
.EXAMPLE
    .\Reset-PortalIndex.ps1 -Action RebuildConfig             # certs/config damaged, no golden copy
.EXAMPLE
    .\Reset-PortalIndex.ps1 -Action RebuildConfig -WithResetCluster   # config AND cluster data damaged
.EXAMPLE
    .\Reset-PortalIndex.ps1 -Action Rollback -BackupName 20261025-101500_ResetCluster

.NOTES
    Copyright (c) 2026 Ope Ltd. All rights reserved.
    NOT an Esri product. NOT supported, endorsed or reviewed by Esri. Works directly on Portal's files outside
    Esri's supported administration interfaces and may put a deployment into a state Esri Support will not
    assist with. Provided AS IS without warranty of any kind; Ope Ltd accepts no liability for data loss,
    downtime or any other consequence of its use. USE AT YOUR OWN DISCRETION AND RISK. Rehearse on a
    non-production machine first and keep current backups (webgisdr and a golden config).

    Written against Portal for ArcGIS 12.1 (build 20379) / OpenSearch 2.18.0 on Windows Server 2022.
    Verified 24 Oct 2026 on OPENZPTL12X: a cluster with a truncated nodes\0\_state\segments_* file
    (OpenSearch failing with CorruptIndexException at NodeEnvironment.loadNodeMetadata) was reset with
    ResetCluster. Service stopped in 12 s, OpenSearch answered 4 min 33 s after service start, Portal
    created its indices on the new cluster, and a Full Reindex from the UI restored 13,652 items / 498
    groups / 51 users with database and index counts matching (syncStatus true). No rollback needed.
    Same day: moving the whole index directory aside and starting Portal produced NOTHING (Portal logged
    "Started Index Service" after 15 s and then failed every health check); Portal Admin > Reconfigure
    in that state also created nothing. Hence RebuildConfig, which regenerates the config itself.
    RebuildConfig verified live the same day: with certs, opensearch.yml, jvm.options, log4j2, keystore and
    all security yml except internal_users.yml deleted, it rebuilt config\ (cluster identity taken from
    spatiotemporal-config.json) and OpenSearch was up 4 min 38 s after service start with all five indices
    and their data intact. ResetCluster -FromGolden also verified live (4 min 36 s), and RebuildConfig
    -WithResetCluster with config and cluster state both damaged (4 min 33 s, Full Reindex afterwards).
    Service name assumed 'Portal for ArcGIS'.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Diagnose', 'SaveGoldenConfig', 'ResetCluster', 'RebuildConfig', 'Rollback')]
    [string]$Action,
    [string]$InstallDir,
    [string]$IndexDir,
    [string]$BackupRoot,
    [string]$GoldenDir,
    [switch]$FromGolden,
    [switch]$WithResetCluster,
    [string]$BackupName,
    [int]$WaitMinutes = 20,
    [switch]$Force,
    [switch]$LabNoService
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$script:ServiceName = 'Portal for ArcGIS'
$script:Stamp       = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:ClientCert  = $null
$script:InstallDirSource = ''
$script:IndexDirSource   = ''
$script:PropsSource      = ''

# ----------------------------------------------------------------------------- output helpers
function Write-Step([string]$msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host ("[{0}]   OK  {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -ForegroundColor Green }
function Write-Bad([string]$msg)  { Write-Host ("[{0}]   !!  {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -ForegroundColor Yellow }
function Confirm-Or-Abort([string]$what) {
    if ($Force) { return }
    if ((Read-Host "$what`nType YES to continue") -ne 'YES') { throw 'Aborted by operator.' }
}

# ----------------------------------------------------------------------------- config discovery
function Read-JavaProperties([string]$path) {
    $h = @{}
    if (-not (Test-Path $path)) { return $h }
    foreach ($line in Get-Content $path) {
        if ($line -match '^\s*[#!]' -or $line -notmatch '=') { continue }
        $k, $v = $line -split '=', 2
        $h[$k.Trim()] = ($v.Trim() -replace '\\(.)', '$1')      # java .properties unescape
    }
    return $h
}
function Read-SimpleYaml([string]$path) {
    $h = @{}
    foreach ($line in Get-Content $path) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*([A-Za-z0-9_.]+)\s*:\s*(.*)$') { continue }
        $h[$Matches[1]] = $Matches[2].Trim()
    }
    return $h
}
function Resolve-InstallDir {
    # Same lookup the Portal installer leaves behind and the qonda_monitor agent uses: the AGSPORTAL
    # machine environment variable. Read the registry copy too, in case this session started before
    # the variable existed. Fall back to the default install path.
    if ($InstallDir) { return @{ Path = $InstallDir.TrimEnd('\'); Source = '-InstallDir parameter' } }
    $v = $env:AGSPORTAL
    if ($v) { return @{ Path = $v.TrimEnd('\'); Source = 'AGSPORTAL (process environment)' } }
    $v = [Environment]::GetEnvironmentVariable('AGSPORTAL', 'Machine')
    if ($v) { return @{ Path = $v.TrimEnd('\'); Source = 'AGSPORTAL (machine environment / registry)' } }
    return @{ Path = 'C:\ArcGIS\Portal'; Source = 'default (AGSPORTAL not set)' }
}

function Resolve-Paths {
    $inst = Resolve-InstallDir
    $script:InstallDir = $inst.Path
    $script:InstallDirSource = $inst.Source
    if (-not (Test-Path $InstallDir)) { throw "Portal install directory not found: $InstallDir (from $($inst.Source)). Pass -InstallDir." }

    # portal-config.properties exists in three places. framework\etc is the live copy Portal writes;
    # etc is the installer's copy (reliable for dir.data); the content store holds Portal's backup.
    $props = @{}
    foreach ($candidate in @((Join-Path $InstallDir 'framework\etc\portal-config.properties'), (Join-Path $InstallDir 'etc\portal-config.properties'))) {
        $p = Read-JavaProperties $candidate
        if ($p.Count -gt 0 -and -not $props.ContainsKey('dir.index')) { $props = $p; $script:PropsSource = $candidate }
    }
    if (-not $props.ContainsKey('dir.index') -and $props['dir.data']) {
        $inner = Join-Path ($props['dir.data'] -replace '/', '\') 'content\items\portal\portal-config.properties'
        $p = Read-JavaProperties $inner
        if ($p.ContainsKey('dir.index')) { $props = $p; $script:PropsSource = $inner }
    }
    if ($IndexDir) { $script:IndexDirSource = '-IndexDir parameter' }
    elseif ($props['dir.index']) { $script:IndexDir = $props['dir.index']; $script:IndexDirSource = "dir.index in $PropsSource" }
    else { $script:IndexDir = 'C:\arcgisportal\index'; $script:IndexDirSource = 'default (dir.index not found in any portal-config.properties)' }
    if (-not $BackupRoot) { $script:BackupRoot = Join-Path (Split-Path $IndexDir -Parent) 'index_backups' }
    if (-not $GoldenDir)  { $script:GoldenDir  = Join-Path $BackupRoot 'golden_config' }

    $script:Paths = [ordered]@{
        InstallDir     = $InstallDir
        IndexDir       = $IndexDir
        NodesDir       = Join-Path $IndexDir 'nodes'
        ConfigDir      = Join-Path $IndexDir 'config'
        ElasticOptions = Join-Path $IndexDir 'elastic.options'
        CertsDir       = Join-Path $IndexDir 'config\certs'
        OpenSearchYml  = Join-Path $IndexDir 'config\opensearch.yml'
        OpenSearchHome = Join-Path $InstallDir 'framework\runtime\ds\framework\runtime\opensearch'
        OpenSsl        = Join-Path $InstallDir 'framework\runtime\ds\bin\openssl.exe'
        DsDataEtc      = Join-Path (Split-Path $IndexDir -Parent) 'dsdata\etc'
        OsLogDir       = Join-Path $InstallDir "framework\runtime\ds\usr\logs\$($env:COMPUTERNAME)\opensearchlog"
        PortalLogDir   = Join-Path (Split-Path $IndexDir -Parent) "logs\$($env:COMPUTERNAME)\portal"
        BackupRoot     = $BackupRoot
        GoldenDir      = $GoldenDir
    }
    $script:Os = @{ HttpPort = 7220; ClusterName = $null; NetworkHost = $null; SeedHosts = $null }
    if (Test-Path $Paths.OpenSearchYml) {
        $y = Read-SimpleYaml $Paths.OpenSearchYml
        if ($y['http.port']) { $Os.HttpPort = [int]$y['http.port'] }
        $Os.ClusterName = $y['cluster.name']; $Os.NetworkHost = $y['network.host']; $Os.SeedHosts = $y['discovery.seed_hosts']
    }
    $script:OsBase = "https://localhost:$($Os.HttpPort)"
}

# ----------------------------------------------------------------------------- OpenSearch access via admin certificate
function Disable-ServerCertCheck {
    # The OpenSearch node certificate is self-signed (CN=*.LOCAL), so server validation must be skipped.
    # On Windows PowerShell a script-block callback is NOT safe: .NET may invoke it on a thread without a
    # runspace, which surfaces as "The underlying connection was closed: An unexpected error occurred on a
    # send". A compiled C# callback has no such problem.
    if ($PSVersionTable.PSEdition -ne 'Core') {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        if (-not ([System.Management.Automation.PSTypeName]'PortalIdx.Tls').Type) {
            Add-Type -TypeDefinition @'
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
namespace PortalIdx {
    public static class Tls {
        public static void TrustAll() {
            ServicePointManager.ServerCertificateValidationCallback =
                delegate (object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) { return true; };
        }
    }
}
'@
        }
        [PortalIdx.Tls]::TrustAll()
    }
}
function Invoke-OpenSsl {
    # Run the bundled openssl and return exit code + combined output as strings. Under
    # $ErrorActionPreference = 'Stop', redirecting a native command's stderr with 2>&1 turns each stderr
    # line into a terminating NativeCommandError; a local 'Continue' keeps it non-terminating.
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $lines = & $Paths.OpenSsl @Arguments 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($lines | Where-Object { $_ }) }
}
function Get-AdminClientCert {
    # admin.pem CN equals the cluster name and is listed in plugins.security.authcz.admin_dn,
    # so the security plugin treats this client certificate as super-admin. No password needed.
    if ($script:ClientCert) { return $script:ClientCert }
    $pem = Join-Path $Paths.CertsDir 'admin.pem'; $key = Join-Path $Paths.CertsDir 'admin-key.pem'
    if (-not (Test-Path $pem) -or -not (Test-Path $key)) { throw "Admin certificate not found in $($Paths.CertsDir)" }
    if (-not (Test-Path $Paths.OpenSsl)) { throw "openssl.exe not found at $($Paths.OpenSsl)" }
    $pfx = Join-Path $env:TEMP ("portalidx-admin-{0}.pfx" -f [guid]::NewGuid())
    $pfxPass = [Convert]::ToBase64String((1..24 | ForEach-Object { [byte](Get-Random -Max 256) }))
    $r = Invoke-OpenSsl @('pkcs12', '-export', '-in', $pem, '-inkey', $key, '-out', $pfx, '-passout', "pass:$pfxPass", '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1')
    if ($r.ExitCode -ne 0 -or -not (Test-Path $pfx)) { throw "openssl pkcs12 export failed (exit $($r.ExitCode)): $($r.Output -join ' ')" }
    try {
        # Schannel can only present a client certificate whose private key lives in a persisted key
        # container. An in-memory (non-persisted) key fails the handshake with "unexpected error on a send".
        $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor
                 [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet -bor
                 [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
        $script:ClientCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfx, $pfxPass, $flags)
    } finally { Remove-Item $pfx -Force -ErrorAction SilentlyContinue }
    return $script:ClientCert
}
function Remove-AdminClientCert {
    # Delete the persisted private-key container created by Get-AdminClientCert.
    if (-not $script:ClientCert) { return }
    try {
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($script:ClientCert)
        if ($rsa -is [System.Security.Cryptography.RSACng]) { $rsa.Key.Delete() }
        elseif ($rsa -is [System.Security.Cryptography.RSACryptoServiceProvider]) { $rsa.PersistKeyInCsp = $false; $rsa.Clear() }
    } catch { }
    try { $script:ClientCert.Reset() } catch { }
    $script:ClientCert = $null
}
function Test-OsTls {
    # Plain HTTPS GET with no client certificate. A 401 proves TLS to the port works and only the
    # certificate authentication is at fault; a transport error means TLS itself is failing.
    Disable-ServerCertCheck
    try {
        $a = @{ Method = 'GET'; Uri = "$OsBase/"; TimeoutSec = 15; UseBasicParsing = $true }
        if ($PSVersionTable.PSEdition -eq 'Core') { $a['SkipCertificateCheck'] = $true }
        Invoke-WebRequest @a | Out-Null
        return 'TLS OK and no authentication required (unexpected: security plugin may be disabled)'
    } catch {
        $resp = $_.Exception.Response
        if ($resp -and [int]$resp.StatusCode -eq 401) { return 'TLS OK, server answered 401 without a certificate: the admin-certificate authentication is what failed' }
        return "TLS/transport failure: $($_.Exception.Message)"
    }
}
function Invoke-Os([string]$Path, [switch]$Quiet) {
    try {
        Disable-ServerCertCheck
        $a = @{ Method = 'GET'; Uri = "$OsBase$Path"; Certificate = (Get-AdminClientCert); TimeoutSec = 30; UseBasicParsing = $true }
        if ($PSVersionTable.PSEdition -eq 'Core') { $a['SkipCertificateCheck'] = $true }
        return Invoke-RestMethod @a
    }
    catch { if (-not $Quiet) { Write-Bad "OpenSearch GET $Path failed: $($_.Exception.Message)" }; return $null }
}
function Invoke-OsText([string]$Path) {
    try {
        Disable-ServerCertCheck
        $a = @{ Method = 'GET'; Uri = "$OsBase$Path"; Certificate = (Get-AdminClientCert); TimeoutSec = 30; UseBasicParsing = $true }
        if ($PSVersionTable.PSEdition -eq 'Core') { $a['SkipCertificateCheck'] = $true }
        return (Invoke-WebRequest @a).Content
    } catch { return "ERROR: $($_.Exception.Message)" }
}

# ----------------------------------------------------------------------------- service / process / file control
function Get-IndexJavaProcesses {
    Get-CimInstance Win32_Process -Filter "Name='java.exe'" | Where-Object {
        $_.CommandLine -and ($_.CommandLine -like "*$IndexDir*" -or $_.CommandLine -like "*$($Paths.OpenSearchHome)*") }
}
function Stop-PortalCompletely {
    if ($LabNoService) { Write-Bad 'LAB MODE: service control skipped'; return }
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { throw "Service '$ServiceName' not found." }
    if ($svc.Status -ne 'Stopped') {
        Write-Step "Stopping service '$ServiceName' (can take a few minutes)"
        Stop-Service -Name $ServiceName -Force
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromMinutes(10))
    }
    Write-Ok 'Service stopped'
    Start-Sleep -Seconds 5
    $zombies = @(Get-IndexJavaProcesses)
    if ($zombies.Count -gt 0) {
        Write-Bad "$($zombies.Count) leftover java.exe process(es) still hold the index (this blocks node.lock):"
        $zombies | ForEach-Object { Write-Host "      PID $($_.ProcessId): $($_.CommandLine.Substring(0, [Math]::Min(150, $_.CommandLine.Length)))" }
        Confirm-Or-Abort 'Kill these leftover OpenSearch processes?'
        $zombies | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        Start-Sleep -Seconds 5
    }
    if (@(Get-IndexJavaProcesses).Count -gt 0) { throw 'OpenSearch java process still running; cannot continue.' }
    Write-Ok 'No OpenSearch processes remain'
}
function Start-PortalAndWait {
    if ($LabNoService) { Write-Bad 'LAB MODE: service start and boot wait skipped'; return $true }
    Write-Step "Starting service '$ServiceName' and waiting up to $WaitMinutes min for OpenSearch"
    Start-Service -Name $ServiceName
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    do {
        Start-Sleep -Seconds 20
        Remove-AdminClientCert                             # certs may have been regenerated; rebuild on next call
        if (Test-Path (Join-Path $Paths.CertsDir 'admin.pem')) {
            $h = Invoke-Os '/_cluster/health' -Quiet
            if ($h) {
                Write-Ok "OpenSearch up: cluster=$($h.cluster_name) status=$($h.status) active_shards=$($h.active_shards) unassigned=$($h.unassigned_shards)"
                return $true
            }
        }
        Write-Host '      ...waiting for OpenSearch'
    } while ((Get-Date) -lt $deadline)
    return $false
}
function New-BackupFolder([string]$label) {
    $dir = Join-Path $BackupRoot "$Stamp`_$label"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Write-Ok "Backup folder: $dir"
    return $dir
}
function Move-Aside([string]$source, [string]$backupDir) {
    if (-not (Test-Path $source)) { Write-Bad "Nothing to move: $source"; return }
    $dest = Join-Path $backupDir (Split-Path $source -Leaf)
    Write-Step "Moving $source -> $dest"
    Move-Item -Path $source -Destination $dest
}
function Copy-Safe([string]$source, [string]$backupDir) {
    if (Test-Path $source) { Copy-Item -Path $source -Destination $backupDir -Recurse -Force }
}
function Show-PostBootState {
    if ($LabNoService) { return }
    # The health endpoint answers the moment the node binds its port, before the security plugin has
    # initialised and before anything has created an index. Wait for those two milestones.
    Write-Step 'Waiting for the security plugin to initialise from config\opensearch-security\*.yml (up to 5 min)'
    $deadline = (Get-Date).AddMinutes(5); $secUp = $false
    do {
        $sec = Invoke-Os '/_plugins/_security/health' -Quiet
        if ($sec -and $sec.status -eq 'UP') { $secUp = $true; Write-Ok "security plugin UP (mode=$($sec.mode))"; break }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    if (-not $secUp) { Write-Bad 'Security plugin not UP after 5 min. Portal cannot authenticate to the index until it is. Check the OpenSearch log.' }

    # Portal does NOT create ago-items / ago-users / ago-groups at startup; the Full Reindex creates them
    # (observed 24 Oct 2026: after a reset the cluster held only .opendistro_security and .plugins-ml-config
    # until the reindex was run). So there is nothing more to wait for here.
    Write-Step 'Indices after boot'
    Write-Host (Invoke-OsText '/_cat/indices?v&h=health,status,index,pri,docs.count,store.size&s=index')
    Write-Host ''
    $idx = Invoke-Os '/_cat/indices?format=json&h=index,docs.count' -Quiet
    $agoDocs = ($idx | Where-Object { $_.index -like 'ago-*' } | ForEach-Object { [int]$_.'docs.count' } | Measure-Object -Sum).Sum
    if ($agoDocs -gt 0) {
        Write-Host 'NEXT: the Portal indices survived with their data. Check Portal Admin > System > Indexer > Status;' -ForegroundColor Green
        Write-Host '      run Reindex (Full) only if a databaseCount differs from its indexCount or syncStatus is false.' -ForegroundColor Green
    } else {
        Write-Host 'NEXT: Portal Admin > System > Indexer > Reindex, mode Full. It creates and fills ago-items / ago-users / ago-groups' -ForegroundColor Green
        Write-Host '      (Portal does not create them at startup). Watch Indexer > Status until every databaseCount equals its indexCount.' -ForegroundColor Green
    }
}

# ----------------------------------------------------------------------------- actions
function Invoke-DiagnoseAction {
    $report = Join-Path (Join-Path $BackupRoot 'diagnostics') $Stamp
    New-Item -ItemType Directory -Force -Path $report | Out-Null
    Start-Transcript -Path (Join-Path $report 'diagnose-transcript.txt') | Out-Null
    try {
        Write-Step 'Paths'
        $Paths.GetEnumerator() | ForEach-Object { Write-Host ("      {0,-15} {1}" -f $_.Key, $_.Value) }
        Write-Host ("      {0,-15} {1}" -f 'InstallDir from', $InstallDirSource)
        Write-Host ("      {0,-15} {1}" -f 'IndexDir from', $IndexDirSource)
        Write-Host ("      OpenSearch      cluster={0} http={1} network.host={2} seeds={3}" -f $Os.ClusterName, $Os.HttpPort, $Os.NetworkHost, $Os.SeedHosts)
        Write-Host ("      golden config   {0}" -f $(if (Test-Path (Join-Path $GoldenDir 'config\opensearch.yml')) { "present ($GoldenDir)" } else { 'NOT SAVED - run -Action SaveGoldenConfig on a healthy day' }))

        Write-Step 'Service and processes'
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        Write-Host "      Service '$ServiceName': $(if ($svc) { $svc.Status } else { 'NOT FOUND' })"
        $procs = @(Get-IndexJavaProcesses)
        Write-Host "      OpenSearch java processes: $($procs.Count)"
        $procs | ForEach-Object { Write-Host "        PID $($_.ProcessId) started $($_.CreationDate)" }

        Write-Step 'Index directory layout'
        foreach ($p in @($Paths.ConfigDir, $Paths.CertsDir, (Join-Path $Paths.ConfigDir 'opensearch-security'), $Paths.ElasticOptions, $Paths.NodesDir, (Join-Path $Paths.NodesDir '0\_state'), (Join-Path $Paths.NodesDir '0\indices'))) {
            Write-Host ("      {0,-8} {1}" -f $(if (Test-Path $p) { 'present' } else { 'MISSING' }), $p)
        }
        $idx = Get-ChildItem (Join-Path $Paths.NodesDir '0\indices') -Directory -ErrorAction SilentlyContinue
        Write-Host "      index folders under nodes\0\indices: $(@($idx).Count)"
        Get-ChildItem -Path $IndexDir -Recurse -Include 'node.lock' -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "      lock: $($_.FullName) ($($_.LastWriteTime)) - harmless unless a java.exe above holds it" }
        $zero = Get-ChildItem $Paths.NodesDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -eq 0 -and $_.Name -notmatch '\.lock$' }
        if ($zero) { Write-Bad "Zero-byte data files (classic hard-reset damage): $(@($zero).Count)"; $zero | Select-Object -First 10 | ForEach-Object { Write-Host "        $($_.FullName)" } }

        Write-Step 'Disk'
        $drive = (Get-Item (Split-Path $IndexDir -Qualifier)).PSDrive
        Write-Host ("      {0}: free {1:N1} GB" -f $drive.Name, ($drive.Free / 1GB))

        Write-Step 'Hostname resolution for names in opensearch.yml (OpenSearch fails to bind if these do not resolve)'
        $names = @($env:COMPUTERNAME) + @([regex]::Matches("$($Os.NetworkHost) $($Os.SeedHosts)", '[A-Za-z_][A-Za-z0-9_\-\.]+') | ForEach-Object { $_.Value -replace ':\d+$', '' } | Where-Object { $_ -notmatch '^_' })
        foreach ($n in ($names | Select-Object -Unique)) {
            try { $ip = ([System.Net.Dns]::GetHostAddresses($n) | Select-Object -First 1).IPAddressToString; Write-Host "      $n -> $ip" }
            catch { Write-Bad "$n does NOT resolve" }
        }

        Write-Step 'Certificates'
        if (Test-Path $Paths.OpenSsl) {
            foreach ($c in 'root-ca.pem', 'node.pem', 'admin.pem') {
                $f = Join-Path $Paths.CertsDir $c
                if (Test-Path $f) {
                    $r = Invoke-OpenSsl @('x509', '-in', $f, '-noout', '-subject', '-enddate')
                    if ($r.ExitCode -eq 0) { Write-Host "      $c : $($r.Output -join ' | ')" } else { Write-Bad "$c UNREADABLE ($((Get-Item $f).Length) bytes): $($r.Output -join ' ')" }
                } else { Write-Bad "$c missing" }
            }
            foreach ($k in 'node-key.pem', 'admin-key.pem') {
                $f = Join-Path $Paths.CertsDir $k
                if (Test-Path $f) {
                    $r = Invoke-OpenSsl @('rsa', '-in', $f, '-check', '-noout')
                    if ($r.ExitCode -eq 0) { Write-Host "      $k : $($r.Output -join ' ')" } else { Write-Bad "$k UNREADABLE ($((Get-Item $f).Length) bytes): $($r.Output -join ' ')" }
                } else { Write-Bad "$k missing" }
            }
            $yml = if (Test-Path $Paths.OpenSearchYml) { Get-Content $Paths.OpenSearchYml -Raw } else { '' }
            if ($yml -match "admin_dn:\s*\r?\n\s*-\s*'([^']+)'") { Write-Host "      admin_dn: $($Matches[1])  (must equal admin.pem CN)" }
            Write-Host "      (node.pem shares the CA DN, so 'openssl verify' calls it self-signed; expected, not a fault)"
        }

        Write-Step 'OpenSearch cluster (admin certificate auth)'
        $certsPresent = (Test-Path (Join-Path $Paths.CertsDir 'admin.pem')) -and (Test-Path (Join-Path $Paths.CertsDir 'admin-key.pem'))
        $h = if ($certsPresent) { Invoke-Os '/_cluster/health' -Quiet } else { $null }
        if (-not $certsPresent) {
            Write-Bad "admin.pem / admin-key.pem missing from $($Paths.CertsDir): cannot query OpenSearch. Repair the config with ResetCluster -FromGolden (menu 4) if a golden copy exists, otherwise RebuildConfig (menu 5)."
            Write-Host "      listener on port $($Os.HttpPort): $(if (Get-NetTCPConnection -State Listen -LocalPort $Os.HttpPort -ErrorAction SilentlyContinue) { 'yes' } else { 'NO - OpenSearch is not listening' })"
        } elseif ($h) {
            Write-Ok "cluster=$($h.cluster_name) status=$($h.status) nodes=$($h.number_of_nodes) active=$($h.active_shards) unassigned=$($h.unassigned_shards)"
            $shards = Invoke-Os '/_cat/shards?format=json&h=index,shard,prirep,state' -Quiet
            if ($shards) {
                $unPrim = @($shards | Where-Object { $_.prirep -eq 'p' -and $_.state -ne 'STARTED' })
                $unRepl = @($shards | Where-Object { $_.prirep -eq 'r' -and $_.state -ne 'STARTED' })
                if ($unPrim.Count -gt 0) { Write-Bad "$($unPrim.Count) PRIMARY shard(s) not started: $(($unPrim | ForEach-Object { "$($_.index)[$($_.shard)]" }) -join ', ') - data in those indices is unavailable" }
                elseif ($h.status -eq 'yellow' -and $h.number_of_nodes -eq 1 -and $unRepl.Count -gt 0) { Write-Host "      yellow = $($unRepl.Count) replica shard(s) with nowhere to go on a one-node cluster. All primaries started. This is the normal state here, not a fault." }
            }
            Write-Host (Invoke-OsText '/_cat/indices?v&h=health,status,index,uuid,pri,rep,docs.count,store.size&s=index')
            Write-Host (Invoke-OsText '/_cat/shards?v&h=index,shard,prirep,state,unassigned.reason,unassigned.details&s=index')
            Write-Host "      security plugin: $((Invoke-Os '/_plugins/_security/health' -Quiet) | ConvertTo-Json -Compress)"
            if ($h.status -eq 'red') { Write-Bad 'Cluster RED. Allocation explanation:'; Write-Host (Invoke-OsText '/_cluster/allocation/explain?pretty') }
            Invoke-OsText '/_cluster/state/metadata,routing_table?pretty' | Out-File (Join-Path $report 'cluster-state.json')
        } else {
            Write-Bad "OpenSearch not reachable on $OsBase with the admin certificate"
            Write-Host "      probe without certificate: $(Test-OsTls)"
            Write-Host "      listener on port $($Os.HttpPort): $(if (Get-NetTCPConnection -State Listen -LocalPort $Os.HttpPort -ErrorAction SilentlyContinue) { 'yes' } else { 'NO - OpenSearch is not listening' })"
        }

        Write-Step 'Log tails (copied into the report folder)'
        $osLog = if ($Os.ClusterName) { Join-Path $Paths.OsLogDir "$($Os.ClusterName).log" } else { '' }
        if (-not $osLog -or -not (Test-Path $osLog)) {
            # opensearch.yml missing or cluster renamed: take the newest main log instead
            $newest = Get-ChildItem $Paths.OsLogDir -Filter 'bds_*.log' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '_(deprecation|index_indexing_slowlog|index_search_slowlog)\.log$' } | Sort-Object LastWriteTime | Select-Object -Last 1
            if ($newest) { $osLog = $newest.FullName }
        }
        if ($osLog -and (Test-Path $osLog)) {
            # The real cause is usually a few lines above a long stack trace. Show the last error/exception
            # lines that are not stack frames, then the raw tail.
            $causes = Get-Content $osLog -Tail 400 | Where-Object { $_ -notmatch '^\s+at ' -and $_ -notmatch '^\s*\.\.\. \d+ more' -and ($_ -match '\[(ERROR|FATAL)\]|Exception|Caused by|Error:') } | Select-Object -Last 6
            if ($causes) { Write-Host "      --- $osLog : last error / exception lines"; $causes | ForEach-Object { Write-Host "      $($_.Substring(0, [Math]::Min(300, $_.Length)))" } }
        }
        foreach ($f in @($osLog, (Join-Path $Paths.OsLogDir 'out.txt'))) {
            if ($f -and (Test-Path $f)) { Copy-Item $f $report -Force; Write-Host "      --- $f (last 20 lines)"; Get-Content $f -Tail 20 | ForEach-Object { Write-Host "      $_" } }
        }
        Get-ChildItem $Paths.OsLogDir -Filter 'hs_err_pid*.log' -ErrorAction SilentlyContinue | ForEach-Object { Write-Bad "JVM crash log present: $($_.FullName)"; Copy-Item $_.FullName $report -Force }
        $lastPortalLog = Get-ChildItem $Paths.PortalLogDir -Filter 'portal-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
        if ($lastPortalLog) {
            Copy-Item $lastPortalLog.FullName $report -Force
            Write-Host "      --- $($lastPortalLog.Name): index-related SEVERE/WARNING (last 12)"
            Select-String -Path $lastPortalLog.FullName -Pattern 'type="(SEVERE|WARNING)"' | Where-Object { $_.Line -match '(?i)index' } | Select-Object -Last 12 |
                ForEach-Object { if ($_.Line -match 'time="([^"]+)".*?>(.*)</Msg>') { Write-Host "      $($Matches[1])  $($Matches[2])" } }
        }
        Write-Host ''
        Write-Host "NOTE: 'Not yet initialized (you may need to run securityadmin)' x3 in the OpenSearch log and Portal's"
        Write-Host "      'Error in generating Portal Indices' appear on EVERY healthy start here (startup race). Not faults by themselves."
        Write-Ok "Report written to $report"
    } finally { Stop-Transcript | Out-Null }
}

function Invoke-SaveGoldenConfigAction {
    if (-not (Test-Path $Paths.OpenSearchYml)) { throw "No opensearch.yml at $($Paths.OpenSearchYml); nothing to save." }
    $h = Invoke-Os '/_cluster/health' -Quiet
    if (-not $h) { Write-Bad 'OpenSearch is not answering right now. A golden copy should be taken from a HEALTHY state.'; Confirm-Or-Abort 'Save anyway?' }
    elseif ($h.status -eq 'red') { Write-Bad 'Cluster is RED right now.'; Confirm-Or-Abort 'Save config anyway?' }
    if (Test-Path $GoldenDir) { Move-Item $GoldenDir "$GoldenDir`_replaced_$Stamp" }
    New-Item -ItemType Directory -Force -Path $GoldenDir | Out-Null
    Copy-Item $Paths.ConfigDir (Join-Path $GoldenDir 'config') -Recurse -Force
    Copy-Item $Paths.ElasticOptions $GoldenDir -Force
    Copy-Safe (Join-Path $Paths.DsDataEtc '*.json') $GoldenDir
    "saved $Stamp from $env:COMPUTERNAME cluster=$($Os.ClusterName) status=$(if ($h) { $h.status } else { 'unknown' })" | Out-File (Join-Path $GoldenDir 'README.txt')
    Write-Ok "Golden config saved to $GoldenDir (config\, elastic.options, dsdata etc json). Keep a copy off the machine too."
    Write-Host '      Contains private keys and the encrypted index credentials: protect it like a certificate store.'
}

function Invoke-ResetClusterAction {
    if ($FromGolden -and -not (Test-Path (Join-Path $GoldenDir 'config\opensearch.yml'))) { throw "No golden config at $GoldenDir. Run -Action SaveGoldenConfig on a healthy machine first." }
    Confirm-Or-Abort @"
OFFLINE RESET to an EMPTY index$(if ($FromGolden) { ' + golden config' }):
  1. Stop '$ServiceName' and any leftover OpenSearch java.exe
  2. Move $($Paths.NodesDir) -> $BackupRoot\$Stamp`_ResetCluster\nodes
$(if ($FromGolden) { "  2b. Move config\ and elastic.options aside and restore them from $GoldenDir`n" })  3. Start Portal. OpenSearch forms a fresh empty cluster; the security index is rebuilt from
     config\opensearch-security\*.yml.
  4. YOU then run Portal Admin > System > Indexer > Reindex (Full), which creates and fills ago-* .
Rollback: -Action Rollback -BackupName $Stamp`_ResetCluster
"@
    $bk = New-BackupFolder 'ResetCluster'
    Copy-Safe (Join-Path $Paths.DsDataEtc '*.json') $bk
    Stop-PortalCompletely
    Move-Aside $Paths.NodesDir $bk
    if ($FromGolden) {
        Move-Aside $Paths.ConfigDir $bk
        Move-Aside $Paths.ElasticOptions $bk
        Copy-Item (Join-Path $GoldenDir 'config') $Paths.ConfigDir -Recurse -Force
        Copy-Item (Join-Path $GoldenDir 'elastic.options') $Paths.ElasticOptions -Force
        Write-Ok "config\ and elastic.options restored from golden copy"
    }
    if (Start-PortalAndWait) { Show-PostBootState; return }

    Write-Bad 'OpenSearch did not start with an empty nodes directory. Rolling back.'
    Stop-PortalCompletely
    if (Test-Path $Paths.NodesDir) { Move-Item $Paths.NodesDir (Join-Path $bk 'nodes_failed_attempt') }
    Move-Item (Join-Path $bk 'nodes') $Paths.NodesDir
    if ($FromGolden) {
        Remove-Item $Paths.ConfigDir -Recurse -Force; Move-Item (Join-Path $bk 'config') $Paths.ConfigDir
        Remove-Item $Paths.ElasticOptions -Force -ErrorAction SilentlyContinue; Move-Item (Join-Path $bk 'elastic.options') $Paths.ElasticOptions
    }
    if (-not $LabNoService) { Start-Service -Name $ServiceName }
    throw "Rolled back. Read $($Paths.OsLogDir)\<cluster>.log for the boot error. Next step: -Action RebuildConfig (regenerates certs + yml) or webgisdr restore."
}

# ----------------------------------------------------------------------------- config regeneration
function Get-ClusterSettings([string]$oldYml) {
    # Cluster identity for a rebuilt config: the old opensearch.yml if still readable, otherwise the
    # Data Store runtime's record in dsdata\etc\spatiotemporal-config.json (lives outside the index dir).
    $s = @{ ClusterName = $null; NodeName = $env:COMPUTERNAME; HttpPort = 7220; TransportPort = 7120; Source = '' }
    if ($oldYml -and (Test-Path $oldYml)) {
        try {
            $y = Read-SimpleYaml $oldYml
            if ($y['cluster.name'] -match '^bds_[a-z0-9]+$') {
                $s.ClusterName = $y['cluster.name']; $s.Source = 'existing opensearch.yml'
                if ($y['node.name'])          { $s.NodeName = $y['node.name'] }
                if ($y['http.port'])          { $s.HttpPort = [int]$y['http.port'] }
                if ($y['transport.tcp.port']) { $s.TransportPort = [int]$y['transport.tcp.port'] }
            }
        } catch { }
    }
    if (-not $s.ClusterName) {
        $json = Join-Path $Paths.DsDataEtc 'spatiotemporal-config.json'
        if (Test-Path $json) {
            try {
                $j = Get-Content $json -Raw | ConvertFrom-Json
                if ($j.'datastore.name' -match '^bds_[a-z0-9]+$') {
                    $s.ClusterName = $j.'datastore.name'; $s.Source = $json
                    if ($j.'db.host')      { $s.NodeName = $j.'db.host' }
                    if ($j.'db.http')      { $s.HttpPort = [int]$j.'db.http' }
                    if ($j.'db.transport') { $s.TransportPort = [int]$j.'db.transport' }
                }
            } catch { }
        }
    }
    if (-not $s.ClusterName) { throw "Cannot determine the cluster name: neither $oldYml nor $($Paths.DsDataEtc)\spatiotemporal-config.json is readable. Restore from a golden copy or webgisdr." }
    return $s
}

function New-PortalIndexCerts([string]$certsDir, [string]$clusterName, [string]$keepCaKeyIn) {
    # Reproduces Portal's own certificate set (verified byte-for-byte in size against the originals):
    # RSA 2048, PKCS#8 keys, 10-year validity, CA and node cert CN=*.LOCAL (CA has critical CA:TRUE),
    # admin cert CN=<cluster name upper case>. The CA key is kept only in the backup folder.
    New-Item -ItemType Directory -Force -Path $certsDir | Out-Null
    $env:OPENSSL_CONF = Join-Path (Split-Path $Paths.OpenSsl -Parent) 'openssl.cnf'
    $caKey = Join-Path $certsDir 'root-ca-key.pem'
    $steps = @(
        @('genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', $caKey),
        @('req', '-new', '-x509', '-key', $caKey, '-subj', '/CN=*.LOCAL', '-days', '3650', '-addext', 'basicConstraints=critical,CA:TRUE', '-out', (Join-Path $certsDir 'root-ca.pem')),
        @('genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', (Join-Path $certsDir 'node-key.pem')),
        @('req', '-new', '-key', (Join-Path $certsDir 'node-key.pem'), '-subj', '/CN=*.LOCAL', '-out', (Join-Path $certsDir 'node.csr')),
        @('x509', '-req', '-in', (Join-Path $certsDir 'node.csr'), '-CA', (Join-Path $certsDir 'root-ca.pem'), '-CAkey', $caKey, '-CAcreateserial', '-days', '3650', '-out', (Join-Path $certsDir 'node.pem')),
        @('genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', (Join-Path $certsDir 'admin-key.pem')),
        @('req', '-new', '-key', (Join-Path $certsDir 'admin-key.pem'), '-subj', "/CN=$($clusterName.ToUpper())", '-out', (Join-Path $certsDir 'admin.csr')),
        @('x509', '-req', '-in', (Join-Path $certsDir 'admin.csr'), '-CA', (Join-Path $certsDir 'root-ca.pem'), '-CAkey', $caKey, '-CAcreateserial', '-days', '3650', '-out', (Join-Path $certsDir 'admin.pem'))
    )
    foreach ($argv in $steps) {
        $r = Invoke-OpenSsl $argv
        if ($r.ExitCode -ne 0) { throw "openssl $($argv[0]) failed: $($r.Output -join ' ')" }
    }
    Remove-Item (Join-Path $certsDir 'node.csr'), (Join-Path $certsDir 'admin.csr'), (Join-Path $certsDir 'root-ca.srl') -Force -ErrorAction SilentlyContinue
    if ($keepCaKeyIn) { Move-Item $caKey (Join-Path $keepCaKeyIn 'root-ca-key.pem') -Force } else { Remove-Item $caKey -Force }
    $v = Invoke-OpenSsl @('verify', '-CAfile', (Join-Path $certsDir 'root-ca.pem'), (Join-Path $certsDir 'admin.pem'))
    if ($v.ExitCode -ne 0) { throw "generated admin certificate does not verify against the new CA: $($v.Output -join ' ')" }
    Write-Ok "certificates generated in $certsDir (CA/node CN=*.LOCAL, admin CN=$($clusterName.ToUpper()))"
}

function New-OpenSearchYml([hashtable]$s) {
    # Layout taken from the opensearch.yml Portal 12.1 generated on this deployment, with the
    # deployment-specific values substituted.
    $data = ($IndexDir -replace '\\', '/')
    $logs = ((Join-Path $InstallDir "framework/runtime/ds/usr/logs/$($s.NodeName)/opensearchlog") -replace '\\', '/')
    $admin = "CN=$($s.ClusterName.ToUpper())"
    return @"
# ---------------------------------- Cluster -----------------------------------
cluster.name:   $($s.ClusterName)

# ------------------------------------ Node ------------------------------------
bootstrap.system_call_filter: false
node.name:   $($s.NodeName)
node.roles: [cluster_manager, data]

# ----------------------------------- Paths ------------------------------------
path.data:   $data
path.logs:   $logs

# ----------------------------------- Memory -----------------------------------
#bootstrap.memory_lock: true
indices.breaker.total.use_real_memory:   false
#indices.breaker.total.limit: 95%
# ---------------------------------- Network -----------------------------------
network.host:  _site_,$($s.NodeName),_local_
http.port:   $($s.HttpPort)
transport.tcp.port:  $($s.TransportPort)
#network.publish_host: hostname
# --------------------------------- Discovery ----------------------------------
discovery.seed_hosts:         ["$($s.NodeName):$($s.TransportPort)"]
cluster.initial_cluster_manager_nodes:   ["$($s.NodeName)"]
cluster.max_shards_per_node: 6000

# --------------------------------- Indices ------------------------------------
indices.query.bool.max_clause_count: 2048

# ---------------------------------- Thread pool -------------------------------
thread_pool.write.queue_size: 10000
thread_pool.search.queue_size: 10000

# ---------------------------------- Repository --------------------------------
path.repo: []

# ---------------------------------- Security --------------------------------
plugins.security.disabled:  false

plugins.security.ssl.transport.enforce_hostname_verification: false

plugins.security.ssl.transport.resolve_hostname: false

plugins.security.roles_mapping_resolution: MAPPING_ONLY

plugins.security.restapi.roles_enabled: ["all_access", "security_rest_api_access"]

plugins.security.allow_default_init_securityindex: true

plugins.security.nodes_dn_dynamic_config_enabled: false

plugins.security.ssl.http.enabled:  true

plugins.security.allow_unsafe_democertificates: true

plugins.security.enable_snapshot_restore_privilege: true

plugins.security.check_snapshot_restore_write_privileges: true

plugins.security.system_indices.enabled: true

plugins.security.system_indices.indices: [".plugins-ml-model", ".plugins-ml-task", ".opendistro-alerting-config", ".opendistro-alerting-alert*", ".opendistro-anomaly-results*", ".opendistro-anomaly-detector*", ".opendistro-anomaly-checkpoints", ".opendistro-anomaly-detection-state", ".opendistro-reports-*", ".opensearch-notifications-*", ".opensearch-notebooks", ".opensearch-observability", ".opendistro-asynchronous-search-response*", ".replication-metadata-store"]

compatibility.override_main_response_version : true


plugins.security.authcz.admin_dn:
  - '$admin'
plugins.security.ssl.transport.pemcert_filepath: certs/node.pem
plugins.security.ssl.transport.pemkey_filepath: certs/node-key.pem
plugins.security.ssl.transport.pemtrustedcas_filepath: certs/root-ca.pem
plugins.security.nodes_dn:
  - 'CN=*.LOCAL'
plugins.security.ssl.http.pemcert_filepath: certs/node.pem
plugins.security.ssl.http.pemkey_filepath: certs/node-key.pem
plugins.security.ssl.http.pemtrustedcas_filepath: certs/root-ca.pem
plugins.security.ssl.transport.enabled_protocols:
  - "TLSv1.2"
  - "TLSv1.3"

plugins.security.ssl.http.enabled_protocols:
  - "TLSv1.2"
  - "TLSv1.3"

cluster.routing.allocation.disk.threshold_enabled: false
"@
}

function Test-FileUsable([string]$path, [string]$mustMatch) {
    if (-not (Test-Path $path)) { return $false }
    if ((Get-Item $path).Length -eq 0) { return $false }
    if ($mustMatch) { return [bool](Select-String -Path $path -Pattern $mustMatch -Quiet) }
    return $true
}

function Invoke-RebuildConfigAction {
    $oldCfg   = $Paths.ConfigDir
    $oldUsers = Join-Path $oldCfg 'opensearch-security\internal_users.yml'
    $tplDir   = Join-Path $InstallDir 'framework\runtime\ds\framework\template\opensearch'
    $instSec  = Join-Path $Paths.OpenSearchHome 'config\opensearch-security'
    if (-not (Test-Path $Paths.OpenSsl)) { throw "openssl.exe not found at $($Paths.OpenSsl)" }
    if (-not (Test-Path $instSec))       { throw "Security yml templates not found at $instSec" }

    # The two files that cannot be regenerated. Both must be intact or the rebuilt index would not
    # accept Portal's credentials.
    $usersOk   = Test-FileUsable $oldUsers 'hash:\s*"\$2'
    $elasticOk = Test-FileUsable $Paths.ElasticOptions 'v2Crypt'
    # internal_users.yml is only read when OpenSearch has to initialise the security index from files.
    # If nodes\ still holds a .opendistro_security index (and we are keeping nodes\), the live hash is in
    # there and the yml is not needed.
    $secIndexOnDisk = $false
    if (-not $WithResetCluster) {
        $stateFiles = Get-ChildItem (Join-Path $Paths.NodesDir '0\indices\*\_state\*.st') -ErrorAction SilentlyContinue
        if ($stateFiles) { $secIndexOnDisk = [bool]($stateFiles | Select-String -Pattern '\.opendistro_security' -Quiet) }
    }
    $usersNeeded = $WithResetCluster -or -not $secIndexOnDisk
    if (-not $elasticOk -or ($usersNeeded -and -not $usersOk)) {
        throw @"
RebuildConfig cannot proceed: the credential files are not intact.
  elastic.options usable:    $elasticOk ($($Paths.ElasticOptions))
  internal_users.yml usable: $usersOk   ($oldUsers)   needed: $usersNeeded $(if ($usersNeeded) { '(cluster will be emptied, or no security index found in nodes\)' } else { '(live security index present in nodes\)' })
These hold Portal's index password (encrypted) and its hash; neither can be regenerated by this script and
Portal offers no API to set a new one. Options: -Action ResetCluster -FromGolden (golden copy), webgisdr
restore, or Esri Support.
"@
    }
    if (-not $usersOk) { Write-Bad "internal_users.yml is unusable; proceeding because the live security index in nodes\ holds the credentials. The template (no users) will be written in its place: if OpenSearch ever re-initialises security from files, Portal cannot authenticate until a golden copy is restored." }
    $s = Get-ClusterSettings $Paths.OpenSearchYml
    Confirm-Or-Abort @"
OFFLINE CONFIG REBUILD (no golden copy needed)$(if ($WithResetCluster) { ' + EMPTY CLUSTER' }):
  cluster=$($s.ClusterName) node=$($s.NodeName) http=$($s.HttpPort) transport=$($s.TransportPort)   (from $($s.Source))
  1. Stop '$ServiceName' and any leftover OpenSearch java.exe
  2. Move $oldCfg -> $BackupRoot\$Stamp`_RebuildConfig\config
$(if ($WithResetCluster) { "  2b. Move $($Paths.NodesDir) -> $BackupRoot\$Stamp`_RebuildConfig\nodes`n" })  3. Create a new config\: fresh CA/node/admin certificates (openssl, Portal's recipe), opensearch.yml,
     jvm.options, log4j2.properties, opensearch-security\*.yml from Esri's templates
  4. Carry over unchanged: elastic.options and opensearch-security\internal_users.yml (the credential pair),
     opensearch.keystore if present
  5. Start Portal and wait for OpenSearch. Rollback automatically if it does not come up.
  6. YOU then run Portal Admin > System > Indexer > Reindex (Full) if the cluster was emptied or counts differ
     (the reindex creates ago-* ), and -Action SaveGoldenConfig because the certificates have changed.
Rollback: -Action Rollback -BackupName $Stamp`_RebuildConfig
"@
    $bk = New-BackupFolder 'RebuildConfig'
    Copy-Safe (Join-Path $Paths.DsDataEtc '*.json') $bk
    Copy-Item $Paths.ElasticOptions (Join-Path $bk 'elastic.options.copy') -Force
    Stop-PortalCompletely
    Move-Aside $oldCfg $bk
    if ($WithResetCluster) { Move-Aside $Paths.NodesDir $bk }
    $bkCfg = Join-Path $bk 'config'

    try {
        Write-Step 'Building new config\'
        New-Item -ItemType Directory -Force -Path $oldCfg, (Join-Path $oldCfg 'opensearch-security') | Out-Null
        New-PortalIndexCerts (Join-Path $oldCfg 'certs') $s.ClusterName $bk

        Set-Content -Path $Paths.OpenSearchYml -Value (New-OpenSearchYml $s) -Encoding ASCII
        Write-Ok 'opensearch.yml written'

        # jvm.options: keep the old one if it is intact (it carries Portal's heap choice), else template with 2 GB.
        $oldJvm = Join-Path $bkCfg 'jvm.options'
        if (Test-FileUsable $oldJvm '^-Xmx') { Copy-Item $oldJvm (Join-Path $oldCfg 'jvm.options') }
        else { (Get-Content (Join-Path $tplDir 'jvm.options')) -replace '^(## )?-Xm([sx])\d+m$', '$1-Xm${2}2048m' | Set-Content (Join-Path $oldCfg 'jvm.options') -Encoding ASCII }
        $oldLog = Join-Path $bkCfg 'log4j2.properties'
        if (Test-FileUsable $oldLog 'appender') { Copy-Item $oldLog (Join-Path $oldCfg 'log4j2.properties') }
        else { Copy-Item (Join-Path $tplDir 'log4j2.properties') (Join-Path $oldCfg 'log4j2.properties') }
        $oldKs = Join-Path $bkCfg 'opensearch.keystore'
        if (Test-FileUsable $oldKs) { Copy-Item $oldKs (Join-Path $oldCfg 'opensearch.keystore') }   # else OpenSearch creates one at start
        Write-Ok 'jvm.options / log4j2.properties / keystore in place'

        Get-ChildItem $instSec -Filter '*.yml' | Where-Object { $_.Name -ne 'internal_users.yml' } | Copy-Item -Destination (Join-Path $oldCfg 'opensearch-security')
        # the old config now lives in the backup folder; the credential hash comes from there
        $bkUsers = Join-Path $bkCfg 'opensearch-security\internal_users.yml'
        if (Test-FileUsable $bkUsers 'hash:\s*"\$2') { Copy-Item $bkUsers (Join-Path $oldCfg 'opensearch-security\internal_users.yml') -Force }
        else { Copy-Item (Join-Path $instSec 'internal_users.yml') (Join-Path $oldCfg 'opensearch-security\internal_users.yml') -Force; Write-Bad 'internal_users.yml written from the empty template (see warning above)' }
        Set-Content -Path (Join-Path $oldCfg 'opensearch-security\opensearch.yml') -Encoding ASCII -Value @"

plugins.security.nodes_dn_dynamic_config_enabled: false
plugins.security.roles_mapping_resolution: MAPPING_ONLY
plugins.security.audit.type: internal_opensearch

plugins.security.authcz.admin_dn:
  - 'CN=$($s.ClusterName.ToUpper())'
plugins.security.nodes_dn:
  - 'CN=*.LOCAL'
"@
        Write-Ok 'opensearch-security\ rebuilt from templates; internal_users.yml carried over'
        Write-Ok "elastic.options left in place ($((Get-Item $Paths.ElasticOptions).Length) bytes)"
    } catch {
        Write-Bad "Rebuild failed while writing files: $($_.Exception.Message). Restoring the old config."
        if (Test-Path $oldCfg) { Move-Item $oldCfg (Join-Path $bk 'config_failed_attempt') }
        Move-Item $bkCfg $oldCfg
        if ($WithResetCluster -and (Test-Path (Join-Path $bk 'nodes'))) { Move-Item (Join-Path $bk 'nodes') $Paths.NodesDir }
        if (-not $LabNoService) { Start-Service -Name $ServiceName }
        throw
    }

    # Config changed: re-read ports/cluster name so the boot check talks to the right place.
    $script:ClientCert = $null
    $script:Os.ClusterName = $s.ClusterName; $script:Os.HttpPort = $s.HttpPort; $script:OsBase = "https://localhost:$($s.HttpPort)"

    if (Start-PortalAndWait) {
        Show-PostBootState
        Write-Host '      Certificates have changed: run -Action SaveGoldenConfig once Portal is healthy.' -ForegroundColor Green
        return
    }
    Write-Bad 'OpenSearch did not start on the rebuilt config. Rolling back.'
    Stop-PortalCompletely
    if (Test-Path $oldCfg) { Move-Item $oldCfg (Join-Path $bk 'config_failed_attempt') }
    Move-Item $bkCfg $oldCfg
    if ($WithResetCluster) {
        if (Test-Path $Paths.NodesDir) { Move-Item $Paths.NodesDir (Join-Path $bk 'nodes_failed_attempt') }
        Move-Item (Join-Path $bk 'nodes') $Paths.NodesDir
    }
    if (-not $LabNoService) { Start-Service -Name $ServiceName }
    throw "Rolled back. Read $($Paths.OsLogDir)\$($s.ClusterName).log for the boot error. Remaining options: golden copy, webgisdr restore, Esri Support."
}

function Invoke-RollbackAction {
    if (-not $BackupName) {
        Write-Host "Available backups in $BackupRoot :"
        Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^(diagnostics|golden_config)' } | ForEach-Object { Write-Host "  $($_.Name)" }
        throw 'Specify -BackupName.'
    }
    $bk = Join-Path $BackupRoot $BackupName
    if (-not (Test-Path $bk)) { throw "Backup not found: $bk" }
    $hasIndex = Test-Path (Join-Path $bk 'index'); $hasNodes = Test-Path (Join-Path $bk 'nodes'); $hasConfig = Test-Path (Join-Path $bk 'config')
    if (-not $hasIndex -and -not $hasNodes -and -not $hasConfig) { throw "Backup $bk holds no 'index', 'nodes' or 'config' folder." }
    $what = if ($hasIndex) { 'the whole index directory' } else { (@() + $(if ($hasNodes) { 'nodes' }) + $(if ($hasConfig) { 'config (+ elastic.options if saved)' })) -join ' + ' }
    Confirm-Or-Abort "Stop Portal and restore $what from $bk."
    Stop-PortalCompletely
    $replaced = Join-Path $bk "replaced_$Stamp"; New-Item -ItemType Directory -Force -Path $replaced | Out-Null
    if ($hasIndex) {
        if (Test-Path $IndexDir) { Move-Item $IndexDir (Join-Path $replaced 'index') }
        Move-Item (Join-Path $bk 'index') $IndexDir
    } else {
        if ($hasNodes) {
            if (Test-Path $Paths.NodesDir) { Move-Item $Paths.NodesDir (Join-Path $replaced 'nodes') }
            Move-Item (Join-Path $bk 'nodes') $Paths.NodesDir
        }
        if ($hasConfig) {
            if (Test-Path $Paths.ConfigDir) { Move-Item $Paths.ConfigDir (Join-Path $replaced 'config') }
            Move-Item (Join-Path $bk 'config') $Paths.ConfigDir
            if (Test-Path (Join-Path $bk 'elastic.options')) {
                if (Test-Path $Paths.ElasticOptions) { Move-Item $Paths.ElasticOptions (Join-Path $replaced 'elastic.options') }
                Move-Item (Join-Path $bk 'elastic.options') $Paths.ElasticOptions
            }
        }
    }
    Write-Ok "Restored. The data that was replaced is kept in $replaced"
    Start-PortalAndWait | Out-Null
}

# ----------------------------------------------------------------------------- main
Resolve-Paths
New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
$transcript = Join-Path $BackupRoot ("{0}_{1}_transcript.txt" -f $Stamp, $Action)
if ($Action -ne 'Diagnose') { Start-Transcript -Path $transcript | Out-Null }
try {
    Write-Step "Action=$Action  InstallDir=$InstallDir  IndexDir=$IndexDir"
    switch ($Action) {
        'Diagnose'         { Invoke-DiagnoseAction }
        'SaveGoldenConfig' { Invoke-SaveGoldenConfigAction }
        'ResetCluster'     { Invoke-ResetClusterAction }
        'RebuildConfig'    { Invoke-RebuildConfigAction }
        'Rollback'         { Invoke-RollbackAction }
    }
    Write-Ok 'Done.'
} finally {
    Remove-AdminClientCert
    if ($Action -ne 'Diagnose') { Stop-Transcript | Out-Null; Write-Host "Transcript: $transcript" }
}
