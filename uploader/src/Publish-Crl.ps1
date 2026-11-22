#Requires -Version 5.1
<#
.SYNOPSIS
    Publishes the CRLs of this CA to S3 at every configured site.

.DESCRIPTION
    Runs on the CA as a Scheduled Task: on CRL publication (Security event 4872) and hourly.
    1. Reads every *.crl (exact extension) from the publish folder, which only the CA writes to, and every *.crt
       from certEnrollDirectory (CA certificates).
       Skips a file that cannot be parsed or has no CRL number. Keeps a private copy of the bytes it
       read; only that copy is uploaded.
    2. Refuses a CRL older than the one it published before (local state file, not S3).
    3. Per site, independently: if the live object is not byte-identical to the source, uploads the source
       (this also repairs missing, junk, old or forged objects). Each object carries metadata.
    4. Logs JSON lines locally and to Splunk HEC.
    Validity dates, signatures and what clients receive are checked by the monitor, not here.

.PARAMETER ConfigPath
    JSON configuration. Default: config.json next to the script.

.PARAMETER DryRun
    Read and compare only. Writes nothing to S3 or to the state file.

.NOTES
    Version 2.4.0.
    Exit codes: 0 ok | 1 config/startup error | 2 some uploads failed | 3 all uploads failed | 4 CRL rejected.
    Requires modules PSPKI and AWS.Tools.S3.
    S3 permissions needed: GetObject and PutObject on the prefix. No ListBucket.
    Secrets: DPAPI files only (site.credentialFile, hec.tokenFile), created as the account that runs the script.
    Object key = keyPrefix + file name (e.g. "mam/ica" -> mam/ica/<name>.crl), matching the URL path.
    CA certificates (AIA): every *.crt in certEnrollDirectory (the CA's CertEnroll folder) is parsed as X.509
    and uploaded to the same keyPrefix. The file name is HOST_NAME.crt: everything before the first underscore
    (the server host name) is dropped, so SERVER01_CA01.crt is published as CA01.crt. A file that does not parse,
    or two files that map to the same name, are rejected. Certificates are not in the CRL rollback state.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'config.json'),
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:Version = '2.4.0'
$script:RunId = [guid]::NewGuid().ToString('N').Substring(0, 12)
$script:EnvName = 'unknown'
$script:LogFile = $null
$script:LogFileBroken = $false
$script:Events = New-Object System.Collections.Generic.List[object]
$script:WorkDir = $null
$script:S3Attempts = 3

# ------------------------------------------------------------------ helpers

function Get-Opt {
    param($Obj, [string] $Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Write-Log {
    param([string] $Level, [string] $EventName, [hashtable] $Data = @{})
    $rec = [ordered]@{
        timestamp   = [DateTime]::UtcNow.ToString('o')
        level       = $Level
        event       = $EventName
        runId       = $script:RunId
        version     = $script:Version
        environment = $script:EnvName
        host        = $env:COMPUTERNAME
    }
    foreach ($k in $Data.Keys) { $rec[$k] = $Data[$k] }
    $script:Events.Add([pscustomobject]@{ Time = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000; Record = $rec })

    if ($script:LogFile -and -not $script:LogFileBroken) {
        try { Add-Content -Path $script:LogFile -Value ($rec | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8 }
        catch {
            $script:LogFileBroken = $true   # warn once, keep running; the events still go to Splunk
            Write-Warning ("cannot write log file $($script:LogFile): " + $_.Exception.Message)
        }
    }
    $text = ($Data.Keys | ForEach-Object { '{0}={1}' -f $_, ($Data[$_] -join ',') }) -join ' '
    Write-Information ('[{0}] {1} {2}' -f $Level.ToUpper(), $EventName, $text) -InformationAction Continue
}

function Get-Sha256Hex {
    param([byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLower() }
    finally { $sha.Dispose() }
}

function Get-ErrorDetail {
    # The whole chain of exception messages, plus the body the server returned (e.g. Splunk's reason for a 400).
    # The outer message ("An error occurred while sending the request") rarely says why; the inner ones do.
    param($ErrorRecord)
    $parts = @()
    $e = $ErrorRecord.Exception
    while ($e) {
        $parts += ('{0}: {1}' -f $e.GetType().Name, $e.Message)
        $e = $e.InnerException
    }
    $body = if ($ErrorRecord.ErrorDetails) { ([string]$ErrorRecord.ErrorDetails.Message -replace '\s+', ' ').Trim() } else { '' }
    if ($body -and -not ($parts -join ' ').Contains($body)) { $parts += ('response: ' + $body) }
    return ($parts -join ' --> ')
}

function Get-HttpStatus {
    # The HTTP status code anywhere in the exception chain (S3 SDK or web request), or 0 when there is none
    # (DNS, connection, TLS, timeout).
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    while ($e) {
        $p = $e.PSObject.Properties['StatusCode']
        if ($p) { $code = $p.Value -as [int]; if ($code -gt 0) { return $code } }
        $r = $e.PSObject.Properties['Response']
        if ($r -and $r.Value -and $r.Value.PSObject.Properties['StatusCode']) {
            $code = $r.Value.StatusCode -as [int]; if ($code -gt 0) { return $code }
        }
        $e = $e.InnerException
    }
    return 0
}

function Invoke-WithRetry {
    # Runs a network call. Retries only what can pass by itself: no HTTP answer (network, timeout),
    # 408, 429 and 5xx. Fails at once on other answers (403 denied, 404 missing, 400 bad request).
    param([scriptblock] $Action, [string] $What, [int] $Attempts = $script:S3Attempts)
    for ($i = 1; ; $i++) {
        try { return (& $Action) }
        catch {
            $status = Get-HttpStatus $_
            $transient = ($status -eq 0) -or ($status -eq 408) -or ($status -eq 429) -or ($status -ge 500)
            if (-not $transient -or $i -ge $Attempts) { throw }
            Write-Log 'warn' 'retry' @{ operation = $What; attempt = $i; httpStatus = $status; error = (Get-ErrorDetail $_) }
            Start-Sleep -Milliseconds ([int](400 * [Math]::Pow(2, $i - 1)) + (Get-Random -Maximum 300))
        }
    }
}

# ------------------------------------------------------------------ CRL (PSPKI)

function Read-CrlNumber {
    # Parses the CRL with PSPKI and returns its CRL number as lower-case hex without leading zeros.
    # Throws when the bytes are not a CRL or the CRL has no number.
    param([byte[]] $Bytes)
    $crl = Get-CertificateRevocationList -RawCRL $Bytes
    $ext = $crl.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.20' } | Select-Object -First 1
    if (-not $ext) { throw 'CRL has no CRL number' }

    # The extension value is a DER INTEGER: 0x02, length (short form), then the value, big-endian.
    $der = [byte[]]$ext.RawData
    $length = if ($der.Length -ge 2) { [int]$der[1] } else { 0 }
    if ($der.Length -lt 3 -or $der[0] -ne 0x02 -or $length -gt 127 -or $der.Length -lt 2 + $length) {
        throw 'malformed CRL number'
    }
    $hex = ([BitConverter]::ToString($der, 2, $length) -replace '-', '').TrimStart('0').ToLower()
    if ($hex) { return $hex }
    return '0'
}

function ConvertFrom-HexNumber {
    # Hex string -> non-negative BigInteger (the leading 0 keeps it positive).
    param([string] $Hex)
    return [Numerics.BigInteger]::Parse('0' + $Hex, [Globalization.NumberStyles]::AllowHexSpecifier)
}

# ------------------------------------------------------------------ state

function Read-PublishState {
    # Returns @{ key -> highest CRL number (hex) published }. Missing file: empty. Unreadable: throws.
    param([string] $Path)
    $numbers = @{}
    if (-not (Test-Path -Path $Path -PathType Leaf)) { return $numbers }
    $raw = Get-Content -Path $Path -Raw | ConvertFrom-Json
    foreach ($p in $raw.PSObject.Properties) {
        if ([string]$p.Value -notmatch '^[0-9a-f]+$') { throw "state file $Path has a bad entry for $($p.Name)" }
        $numbers[$p.Name] = [string]$p.Value
    }
    return $numbers
}

function Save-PublishState {
    # Atomic: write a temp file next to the state file, then replace it.
    param([string] $Path, [hashtable] $Numbers)
    $dir = Split-Path -Parent $Path
    $null = New-Item -Path $dir -ItemType Directory -Force
    $obj = [ordered]@{}
    foreach ($k in ($Numbers.Keys | Sort-Object)) { $obj[$k] = $Numbers[$k] }
    $tmp = Join-Path $dir ('.state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    Move-Item -Path $tmp -Destination $Path -Force
}

# ----------------------------------------------------------------------- S3

function Get-S3Splat {
    # Connection parameters for one site.
    # Keys written in the config (site.accessKey + site.secretKey, plain text) win, and credentialFile is ignored.
    # Otherwise a DPAPI file (Get-Credential | Export-Clixml): user name = Access Key ID, password = Secret Key.
    param($Site)
    if ((Get-Opt $Site 'accessKey') -or (Get-Opt $Site 'secretKey')) {
        $access = [string](Get-Opt $Site 'accessKey' '')
        $secret = [string](Get-Opt $Site 'secretKey' '')
    }
    else {
        $cred = Import-Clixml -Path ([string]$Site.credentialFile)
        $access = $cred.UserName
        $secret = $cred.GetNetworkCredential().Password
    }
    if (-not $access -or -not $secret) { throw "empty S3 credentials in $($Site.credentialFile)" }
    return @{
        EndpointUrl              = [string]$Site.endpoint
        Region                   = [string]$Site.region
        AccessKey                = $access
        SecretKey                = $secret
        ForcePathStyleAddressing = [bool](Get-Opt $Site 'forcePathStyle' $true)
    }
}

function Get-LiveObject {
    # Reads the live object. Returns @{ State = present | missing | denied; Sha256 }.
    # 404 = missing. 403 = denied: some S3 products answer 403 for a missing key when the caller may not list;
    # the object is then uploaded anyway (a real permission problem fails on the upload and is reported).
    param([string] $Bucket, [string] $Key, [hashtable] $S3)
    $file = Join-Path $script:WorkDir ('live-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        try {
            $null = Invoke-WithRetry -What "get $Key" -Action { Read-S3Object -BucketName $Bucket -Key $Key -File $file @S3 }
        }
        catch {
            $status = Get-HttpStatus $_
            if ($status -eq 404) { return @{ State = 'missing'; Sha256 = $null } }
            if ($status -eq 403) { return @{ State = 'denied'; Sha256 = $null } }
            throw
        }
        return @{ State = 'present'; Sha256 = (Get-Sha256Hex ([IO.File]::ReadAllBytes($file))) }
    }
    finally { Remove-Item -Path $file -Force -ErrorAction SilentlyContinue }
}

function Publish-CrlToSite {
    # Returns @{ Result = unchanged | published | dryrun; Live = present | different | missing | denied }.
    # Throws on failure. S3 content is not trusted: anything not byte-identical to the source is overwritten.
    param($Site, [hashtable] $S3, $Item, [bool] $IsDryRun)
    $bucket = [string]$Site.bucket
    $live = Get-LiveObject -Bucket $bucket -Key $Item.Key -S3 $S3
    if ($live.State -eq 'present') {
        if ($live.Sha256 -eq $Item.Sha256) { return @{ Result = 'unchanged'; Live = 'identical' } }
        $live.State = 'different'
    }
    if ($IsDryRun) { return @{ Result = 'dryrun'; Live = $live.State } }

    $meta = @{
        'run-id'           = $script:RunId
        'sha256'           = $Item.Sha256
        'source-host'      = $env:COMPUTERNAME
        'uploader-version' = $script:Version
    }
    if ($Item.Number) { $meta['crl-number-hex'] = $Item.Number }
    $null = Invoke-WithRetry -What "put $($Item.Key)" -Action {
        Write-S3Object -BucketName $bucket -Key $Item.Key -File $Item.Path -ContentType $Item.ContentType -Metadata $meta @S3
    }
    return @{ Result = 'published'; Live = $live.State }
}

# ---------------------------------------------------------------- Splunk HEC

function Send-HecEvent {
    # Sends every event of this run in one request. Token from a DPAPI file
    # (Read-Host -AsSecureString | ConvertFrom-SecureString), the token only, without the word "Splunk".
    # A token written in the config (hec.token, plain text) wins, and tokenFile is ignored.
    param($Hec)
    if (Get-Opt $Hec 'token') { $token = [string]$Hec.token }
    else {
        $secure = (Get-Content -Path ([string]$Hec.tokenFile) -Raw).Trim() | ConvertTo-SecureString
        $token = ([pscredential]::new('hec', $secure)).GetNetworkCredential().Password
    }
    $token = ($token -replace '^\s*Splunk\s+', '').Trim()
    if (-not $token) { throw "empty HEC token in $($Hec.tokenFile)" }

    $source = [string](Get-Opt $Hec 'source' 'Publish-Crl')
    $sourcetype = [string](Get-Opt $Hec 'sourcetype' 'crl:publisher')
    $index = [string](Get-Opt $Hec 'index' '')
    $sb = New-Object System.Text.StringBuilder
    foreach ($e in $script:Events) {
        $w = [ordered]@{ time = $e.Time; host = $env:COMPUTERNAME; source = $source; sourcetype = $sourcetype; event = $e.Record }
        if ($index) { $w['index'] = $index }
        $null = $sb.AppendLine(($w | ConvertTo-Json -Compress -Depth 6))
    }
    $body = [Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $timeout = [int](Get-Opt $Hec 'timeoutSec' 10)

    $null = Invoke-WithRetry -What 'hec post' -Attempts 3 -Action {
        Invoke-RestMethod -Method Post -Uri ([string]$Hec.url) -Headers @{ Authorization = "Splunk $token" } `
            -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec $timeout
    }
}

# ---------------------------------------------------------------------- main

function Get-KeyPrefix {
    param($Config)
    $prefix = ([string](Get-Opt $Config 'keyPrefix' '') -replace '\\', '/').Trim('/')
    if ($prefix) { $prefix += '/' }
    return $prefix
}

function Read-SourceCrl {
    # Every *.crl in the publish folder that parses and has a CRL number. Returns @{ items; rejected }.
    param($Config)
    $dir = [string]$Config.sourceDirectory
    $prefix = Get-KeyPrefix $Config
    $r = @{ items = @(); rejected = 0 }
    $files = @(Get-ChildItem -Path $dir -File | Where-Object { $_.Extension -eq '.crl' } | Sort-Object Name)
    foreach ($file in $files) {
        try {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            $number = Read-CrlNumber -Bytes $bytes
        }
        catch {
            $r.rejected++
            Write-Log 'error' 'crl_rejected' @{ file = $file.Name; error = (Get-ErrorDetail $_) }
            continue
        }
        $copy = Join-Path $script:WorkDir ('src-' + $file.Name)   # upload exactly the bytes that were read
        [IO.File]::WriteAllBytes($copy, $bytes)
        $r.items += [pscustomobject]@{
            Kind = 'crl'; ContentType = 'application/pkix-crl'
            Name = $file.Name; Key = $prefix + $file.Name; Path = $copy; Number = $number; Sha256 = (Get-Sha256Hex $bytes)
        }
    }
    if ($r.items.Count -eq 0) {
        $r.rejected++
        Write-Log 'error' 'no_valid_crl_in_directory' @{ directory = $dir }
    }
    return $r
}

function Get-PublishedCertName {
    # HOST_NAME.crt -> NAME.crt: everything before the first underscore (the host name) is dropped.
    # A name without an underscore is published as it is.
    param([string] $FileName)
    $i = $FileName.IndexOf('_')
    if ($i -ge 0) { return $FileName.Substring($i + 1) }
    return $FileName
}

function Read-SourceCert {
    # Every *.crt in certEnrollDirectory that parses as X.509. Returns @{ items; rejected }.
    param($Config)
    $dir = [string](Get-Opt $Config 'certEnrollDirectory' '')
    $r = @{ items = @(); rejected = 0 }
    if (-not $dir) { return $r }                            # not configured: AIA publishing is off
    if (-not (Test-Path -Path $dir -PathType Container)) {
        $r.rejected++
        Write-Log 'error' 'certenroll_missing' @{ directory = $dir }
        return $r
    }
    $prefix = Get-KeyPrefix $Config
    $seen = @{}
    $files = @(Get-ChildItem -Path $dir -File | Where-Object { $_.Extension -eq '.crt' } | Sort-Object Name)
    foreach ($file in $files) {
        $name = Get-PublishedCertName $file.Name
        try {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$bytes)
            $null = $cert.Subject
        }
        catch {
            $r.rejected++
            Write-Log 'error' 'cert_rejected' @{ file = $file.Name; error = (Get-ErrorDetail $_) }
            continue
        }
        if ($seen.ContainsKey($name)) {
            $r.rejected++
            Write-Log 'error' 'cert_name_collision' @{ file = $file.Name; publishedAs = $name }
            continue
        }
        $seen[$name] = $true
        $copy = Join-Path $script:WorkDir ('cert-' + $name)   # upload exactly the bytes that were read
        [IO.File]::WriteAllBytes($copy, $bytes)
        $r.items += [pscustomobject]@{
            Kind = 'cert'; ContentType = 'application/pkix-cert'
            Name = $name; Key = $prefix + $name; Path = $copy; Number = $null; Sha256 = (Get-Sha256Hex $bytes)
        }
    }
    return $r
}

function Invoke-Publish {
    param($Config, [bool] $IsDryRun)
    $t0 = Get-Date
    $statePath = [string](Get-Opt $Config 'stateFile' (Join-Path $PSScriptRoot 'state\published.json'))
    $s = @{ rejected = 0; published = 0; unchanged = 0; dryrun = 0; failed = 0 }
    $dir = [string]$Config.sourceDirectory
    if (-not (Test-Path -Path $dir -PathType Container)) { throw "sourceDirectory not found: $dir" }
    foreach ($m in 'PSPKI', 'AWS.Tools.S3') {
        if (-not (Get-Module -ListAvailable -Name $m)) { throw "module $m is not installed" }
        $null = Import-Module $m
    }
    $siteNames = @($Config.sites | ForEach-Object { $_.name })
    Write-Log 'info' 'run_start' @{ dryRun = $IsDryRun; keyPrefix = (Get-KeyPrefix $Config); sites = $siteNames }

    $src = Read-SourceCrl -Config $Config
    $s.rejected += $src.rejected
    $certs = Read-SourceCert -Config $Config
    $s.rejected += $certs.rejected
    $published = Read-PublishState -Path $statePath   # a corrupt state file stops the run (fatal, exit 1)
    if (-not (Test-Path -Path $statePath -PathType Leaf)) {
        # Expected on the first run only. Otherwise the rollback protection was lost: a CRL older than the one
        # published before (e.g. after a CA restore) would now be accepted. Alert on it.
        Write-Log 'warn' 'state_missing' @{ stateFile = $statePath }
    }

    # Never go backwards: compare with what this uploader published before.
    $toPublish = @()
    foreach ($item in $src.items) {
        if ($published.ContainsKey($item.Key) -and
            (ConvertFrom-HexNumber $item.Number) -lt (ConvertFrom-HexNumber $published[$item.Key])) {
            $s.rejected++
            Write-Log 'error' 'crl_older_than_published' @{ key = $item.Key; crlNumber = $item.Number; published = $published[$item.Key] }
            continue
        }
        $toPublish += $item
    }
    $toPublish += @($certs.items)

    $landed = @{}
    foreach ($site in @($Config.sites)) {
        try { $s3 = Get-S3Splat -Site $site }
        catch {
            $s.failed += $toPublish.Count
            Write-Log 'error' 'site_unavailable' @{ site = $site.name; error = (Get-ErrorDetail $_) }
            continue
        }
        foreach ($item in $toPublish) {
            $result = 'failed'; $live = $null; $err = $null
            try {
                $r = Publish-CrlToSite -Site $site -S3 $s3 -Item $item -IsDryRun $IsDryRun
                $result = $r.Result; $live = $r.Live
            }
            catch { $err = Get-ErrorDetail $_ }

            $s[$result]++
            if (($result -eq 'published' -or $result -eq 'unchanged') -and $item.Kind -eq 'crl') { $landed[$item.Key] = $item.Number }
            $level = if ($result -eq 'failed') { 'error' } else { 'info' }
            Write-Log $level 'publish' @{ site = $site.name; kind = $item.Kind; key = $item.Key; crlNumber = $item.Number; sha256 = $item.Sha256
                result = $result; live = $live; error = $err }
        }
    }

    if (-not $IsDryRun -and $landed.Count -gt 0) {
        foreach ($k in $landed.Keys) { $published[$k] = $landed[$k] }
        Save-PublishState -Path $statePath -Numbers $published
    }

    $reached = $s.published + $s.unchanged + $s.dryrun
    $code = 0
    if ($s.failed -gt 0 -and $reached -eq 0) { $code = 3 }   # nothing reached S3
    elseif ($s.failed -gt 0) { $code = 2 }
    elseif ($s.rejected -gt 0) { $code = 4 }
    Write-Log 'info' 'run_end' @{ exitCode = $code; published = $s.published; unchanged = $s.unchanged; dryrun = $s.dryrun
        rejected = $s.rejected; failed = $s.failed; durationMs = [int]((Get-Date) - $t0).TotalMilliseconds }
    return $code
}

function Test-Config {
    # Names of missing settings; empty when the configuration is complete.
    param($Config)
    $bad = @()
    if (-not (Get-Opt $Config 'sourceDirectory')) { $bad += 'sourceDirectory' }
    $sites = @(Get-Opt $Config 'sites' @())
    if ($sites.Count -eq 0) { $bad += 'sites' }
    foreach ($x in $sites) {
        foreach ($f in 'name', 'endpoint', 'bucket', 'region') {
            if (-not (Get-Opt $x $f)) { $bad += "site.$f" }
        }
        # Credentials: plain-text keys in the config, or a DPAPI credentialFile.
        if ((Get-Opt $x 'accessKey') -or (Get-Opt $x 'secretKey')) {
            foreach ($f in 'accessKey', 'secretKey') { if (-not (Get-Opt $x $f)) { $bad += "site.$f" } }
        }
        elseif (-not (Get-Opt $x 'credentialFile')) { $bad += 'site.credentialFile' }
    }
    $hec = Get-Opt $Config 'hec'
    if ($hec) {
        if (-not (Get-Opt $hec 'url')) { $bad += 'hec.url' }
        if (-not (Get-Opt $hec 'token') -and -not (Get-Opt $hec 'tokenFile')) { $bad += 'hec.tokenFile' }
    }
    if ([int](Get-Opt $Config 's3Attempts' 3) -lt 1) { $bad += 's3Attempts' }
    return $bad
}

# Dot-sourcing (tests) loads the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

$exitCode = 1
$hec = $null
try {
    $cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    $script:EnvName = [string](Get-Opt $cfg 'environment' 'unknown')
    $script:S3Attempts = [int](Get-Opt $cfg 's3Attempts' 3)
    $hec = Get-Opt $cfg 'hec'

    $logDir = [string](Get-Opt $cfg 'logDirectory' (Join-Path $PSScriptRoot 'logs'))
    $null = New-Item -Path $logDir -ItemType Directory -Force
    $script:LogFile = Join-Path $logDir ('publish-crl-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
    $keepDays = [int](Get-Opt $cfg 'logRetentionDays' 30)
    Get-ChildItem -Path $logDir -Filter 'publish-crl-*.log' -File |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$keepDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $bad = @(Test-Config $cfg)
    if ($bad.Count -gt 0) { throw ('invalid configuration, missing: ' + ($bad -join ', ')) }
    $plain = @(@(Get-Opt $cfg 'sites' @()) | Where-Object { Get-Opt $_ 'secretKey' } | ForEach-Object { [string]$_.name })
    if ($hec -and (Get-Opt $hec 'token')) { $plain += 'hec' }
    if ($plain.Count -gt 0) {
        # Visible in the log and in Splunk on every run, so plain-text secrets are not forgotten after the rollout.
        Write-Log 'warn' 'plaintext_secrets' @{ in = ($plain -join ','); note = 'secrets are written in the config file; move them to DPAPI files (Protect-Secrets.ps1) after the rollout' }
    }

    $script:WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('crl-publish-' + $script:RunId)
    $null = New-Item -Path $script:WorkDir -ItemType Directory -Force

    $exitCode = Invoke-Publish -Config $cfg -IsDryRun $DryRun.IsPresent
}
catch {
    Write-Log 'error' 'fatal' @{ error = (Get-ErrorDetail $_); at = $_.ScriptStackTrace }
    $exitCode = 1
}
finally {
    if ($script:WorkDir) { Remove-Item -Path $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($hec -and (Get-Opt $hec 'url') -and ((Get-Opt $hec 'token') -or (Get-Opt $hec 'tokenFile'))) {
        try { Send-HecEvent -Hec $hec }
        catch { Write-Log 'error' 'hec_failed' @{ httpStatus = (Get-HttpStatus $_); error = (Get-ErrorDetail $_) } }
    }
}
exit $exitCode
