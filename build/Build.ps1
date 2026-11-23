# Build the native portable edition at its normal entry point.
param([string]$OutputDirectory = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Build-Native.ps1') -OutputDirectory $OutputDirectory
