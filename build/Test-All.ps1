$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Test-Native.ps1')
& (Join-Path $PSScriptRoot 'Test-NativeRegression.ps1')
& (Join-Path $PSScriptRoot 'Test-Publication.ps1')
