[CmdletBinding()]
param(
    [string]$Target = ".",
    [switch]$Plan,
    [switch]$Apply,
    [string]$Rollback = "",
    [string]$AdoptFrom = "",
    [string]$ProjectName = "",
    [string[]]$AcceptLocal = @()
)

& (Join-Path $PSScriptRoot "project-flow.ps1") upgrade @PSBoundParameters
$succeeded = $?
$code = $LASTEXITCODE
if (-not $succeeded) { exit $(if ($code -is [int] -and $code -ne 0) { $code } else { 1 }) }
exit 0
