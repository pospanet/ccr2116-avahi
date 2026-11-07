#Requires -Version 5.1
# Windows convenience wrapper for the DHCP lab driver (stdlib Python only).
param(
    [string]$BaseImage = "",
    [switch]$SkipBuild,
    [string]$Only = "",
    [switch]$KeepResources
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
if (-not $py) { Write-Error "python not found on PATH"; exit 2 }
$argsList = @("$here\dhcp_lab.py")
if ($BaseImage)    { $argsList += @("--base-image", $BaseImage) }
if ($SkipBuild)    { $argsList += "--skip-build" }
if ($Only)         { $argsList += @("--only", $Only) }
if ($KeepResources){ $argsList += "--keep-resources" }
& $py.Source @argsList
exit $LASTEXITCODE
