# Windows wrapper pro test/e2e/run.sh
# Spustí bash driver přes Git-Bash (doporučeno) nebo WSL bash.
#
# Env proměnné IMG/TESTIMG/PLATFORM/SUBNET se předávají POUZE do child
# procesu (přes ProcessStartInfo.EnvironmentVariables nebo argv pro `env`),
# NIKDY se nemění env tohoto volajícího procesu - žádné ponechané/přepsané/
# smazané hodnoty. Požadavek: Windows PowerShell 5.1+ nebo PowerShell 7+.
#
# Použití (z kořene repo):
#   .\test\e2e\run.ps1 -Img ccr2116-avahi:local-amd64 -TestImg ccr2116-avahi-e2e:amd64 -Platform linux/amd64
[CmdletBinding()]
param(
  [string]$Img      = 'ccr2116-avahi:local-amd64',
  [string]$TestImg  = '',
  [string]$Platform = 'linux/amd64',
  [string]$Subnet   = '10.90'
)
$ErrorActionPreference = 'Stop'
if (-not $TestImg) { $TestImg = $Img }

# Vstupní validace - odmítnout cokoli, co by mohlo prorazit do shellu/env.
# Hodnoty se nikdy neinterpolují do bash příkazu, jen do child-env/argv.
$safe = '^[A-Za-z0-9._/:@-]+$'
foreach ($n in @('Img','TestImg','Platform')) {
  $v = (Get-Variable $n).Value
  if ($v -notmatch $safe) { Write-Error "Parametr -$n obsahuje nepovolené znaky: '$v'"; exit 2 }
}
# SUBNET = přesně a.b (dva číselné oktety), bounded, bez leading zeros
if ($Subnet -notmatch '^([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-2][0-9])\.([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-5][0-9])$') {
  Write-Error "Parametr -Subnet musí být a.b (dva oktety 0-255, bez leading zeros): '$Subnet'"; exit 2
}
$sp = $Subnet -split '\.'
if ([int]$sp[0] -gt 223) { Write-Error "Parametr -Subnet: první oktet mimo rozsah (>223): '$Subnet'"; exit 2 }

$repo = Resolve-Path "$PSScriptRoot\..\.."
$script = Join-Path $repo 'test\e2e\run.sh'
function ConvertTo-BashPath([string]$p) {
  $p = $p -replace '\\','/'
  if ($p -match '^([A-Za-z]):/(.*)') { return "/$($Matches[1].ToLower())/$($Matches[2])" }
  return $p
}
$bsh = ConvertTo-BashPath $script

# Spustí child proces s env overrides JEN v jeho environment (ne mění
# env tohoto procesu). Kompatibilní s Windows PowerShell 5.1 i PS7:
# ProcessStartInfo.ArgumentList je jen v .NET Core/PS7, ve 5.1 musíme
# sestavit Arguments string s ručním quotingem (argv, ne shell string).
function Quote-Arg([string]$a) {
  # wrap v uvozovky; escapuj vnitřní " a trailing backslashy před "
  $a = $a -replace '"','\"' -replace '(\\+)"','$1$1"'
  return '"' + $a + '"'
}
function Invoke-Child([string]$exe, [string[]]$argv) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = ($argv | ForEach-Object { Quote-Arg $_ }) -join ' '
  $psi.UseShellExecute = $false
  # přepsat/prázdnou hodnotu jen v child env (nikdy $env: tohoto procesu)
  $psi.EnvironmentVariables['IMG']      = $Img
  $psi.EnvironmentVariables['TESTIMG']  = $TestImg
  $psi.EnvironmentVariables['PLATFORM'] = $Platform
  $psi.EnvironmentVariables['SUBNET']   = $Subnet
  $p = [System.Diagnostics.Process]::Start($psi)
  $p.WaitForExit()
  return $p.ExitCode
}

# 1) Git-Bash (docker CLI běží nativně na Windows; bash driver se spustí v bash)
$gitbash = "$env:ProgramFiles\Git\bin\bash.exe"
if (Test-Path $gitbash) {
  exit (Invoke-Child $gitbash @($bsh))
}

# 2) WSL - env se předává explicitně přes `env`, protože WSL nepodědí
#    custom Windows env proměnné. argv forma -> žádná shell interpolace.
if (Get-Command wsl -ErrorAction SilentlyContinue) {
  $wp = ($bsh -replace '^/([a-z])/','/mnt/$1/')
  exit (Invoke-Child 'wsl.exe' @('-e','env',"IMG=$Img","TESTIMG=$TestImg","PLATFORM=$Platform","SUBNET=$Subnet",'bash',$wp))
}

Write-Error "Nenalezen Git-Bash (C:\Program Files\Git\bin\bash.exe) ani WSL bash."
exit 2
