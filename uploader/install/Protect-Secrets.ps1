#Requires -Version 5.1
<#
.SYNOPSIS
    One-time helper: turns plain-text S3 keys and the HEC token into DPAPI-protected files for the account
    that runs it, then deletes the plain-text input.

.DESCRIPTION
    DPAPI files can be read only by the account that wrote them, so this must run AS the uploader's service
    account (a gMSA cannot log on interactively). Run it through a temporary scheduled task; see docs/rollout.md.

    Input (created by an administrator in the secrets folder, deleted by this script):
    {
      "sites": [ { "name": "sou", "accessKey": "...", "secretKey": "..." },
                 { "name": "cen", "accessKey": "...", "secretKey": "..." } ],
      "hecToken": "..."
    }
    Output: <name>.cred per site (PSCredential: user = access key, password = secret key) and hec.token.
#>
[CmdletBinding()]
param(
    [string] $InputFile = 'D:\CrlPublisher\secrets\input.json',
    [string] $OutDir = 'D:\CrlPublisher\secrets'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$log = Join-Path $OutDir 'protect-secrets.log'
try {
    $in = Get-Content -Path $InputFile -Raw | ConvertFrom-Json
    foreach ($site in @($in.sites)) {
        $secure = ConvertTo-SecureString -String ([string]$site.secretKey) -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential ([string]$site.accessKey, $secure)
        $cred | Export-Clixml -Path (Join-Path $OutDir ("{0}.cred" -f $site.name))
    }
    if ($in.PSObject.Properties['hecToken'] -and $in.hecToken) {
        ConvertTo-SecureString -String ([string]$in.hecToken) -AsPlainText -Force | ConvertFrom-SecureString |
            Set-Content -Path (Join-Path $OutDir 'hec.token')
    }
    Set-Content -Path $log -Value ("{0} OK as {1}: {2} site(s)" -f (Get-Date -Format o), [Security.Principal.WindowsIdentity]::GetCurrent().Name, @($in.sites).Count)
}
catch {
    Set-Content -Path $log -Value ("{0} FAILED as {1}: {2}" -f (Get-Date -Format o), [Security.Principal.WindowsIdentity]::GetCurrent().Name, $_.Exception.Message)
    throw
}
finally {
    Remove-Item -Path $InputFile -Force -ErrorAction SilentlyContinue   # never leave plain-text keys behind
}
