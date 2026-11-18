$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$manifest=Get-Content -LiteralPath (Join-Path $root 'site/site-sha256.json') -Raw|ConvertFrom-Json
foreach($file in $manifest.PSObject.Properties){
 if($file.Name -notmatch '^[a-z0-9.-]+$'){throw 'Unsafe website name'}
 if((Get-FileHash -LiteralPath (Join-Path $root ('site/'+$file.Name)) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.Value){throw "Website bytes changed: $($file.Name)"}
}
foreach($name in 'LICENSE','PRIVACY.md','CODE-SIGNING.md','THIRD-PARTY-NOTICES.md','docs/PUBLICATION-REVIEW.md') {if(-not(Test-Path -LiteralPath (Join-Path $root $name))){throw "Missing $name"}}
$files=@(& git -C $root ls-files)
foreach($name in $files){if($name -match '\.(pfx|p12|pem|key|log)$' -or $name -match '(^|/)(reports|scan-history|registry-backups)/'){throw "Sensitive tracked file: $name"}}
Write-Host 'PASS publication documents and exact website bytes'
