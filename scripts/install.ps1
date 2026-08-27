[CmdletBinding()]
param(
    [string]$Target = ".",
    [string]$ProjectName = "",
    [switch]$Force,
    [switch]$DryRun
)

& (Join-Path $PSScriptRoot "project-flow.ps1") install @PSBoundParameters
$succeeded = $?
$code = $LASTEXITCODE
if (-not $succeeded) { exit $(if ($code -is [int] -and $code -ne 0) { $code } else { 1 }) }
exit 0
