[CmdletBinding()]
param([string]$Target = ".", [switch]$AllowPlaceholders)

& (Join-Path $PSScriptRoot "project-flow.ps1") validate @PSBoundParameters
$succeeded = $?
$code = $LASTEXITCODE
if (-not $succeeded) { exit $(if ($code -is [int] -and $code -ne 0) { $code } else { 1 }) }
exit 0
