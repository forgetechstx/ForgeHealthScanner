param([Parameter(Mandatory=$true)][string]$Directory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach($line in [IO.File]::ReadAllLines((Join-Path $Directory 'SHA256SUMS.txt'))){
 if($line -notmatch '^([a-f0-9]{64})  (ForgeHealthScanner-[0-9.]+-portable-unsigned\.(zip|cdx\.json|manifest\.json))$'){throw 'Invalid checksum entry'}
 $expected=$Matches[1];$name=$Matches[2]
 if((Get-FileHash -LiteralPath (Join-Path $Directory $name) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected){throw "Checksum mismatch: $name"}
}
$zips=@(Get-ChildItem -LiteralPath $Directory -Filter '*.zip');if($zips.Count -ne 1){throw 'Expected one package'}
$zip=[IO.Compression.ZipFile]::OpenRead($zips[0].FullName)
try {
 $names=@($zip.Entries|ForEach-Object {$_.FullName})
 $allowed=@('HealthScan.exe','README.md','README.txt','LICENSE','PRIVACY.md','CODE-SIGNING.md','THIRD-PARTY-NOTICES.md')
 if($names.Count -ne $allowed.Count -or @(Compare-Object $names $allowed).Count){throw 'Unexpected or missing package files'}
 $entry=$zip.GetEntry('HealthScan.exe');$stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose();$sha.Dispose()}
 $manifest=Get-Content -LiteralPath ($zips[0].FullName -replace '\.zip$','.manifest.json') -Raw|ConvertFrom-Json
 if($hash -cne $manifest.executableSHA256 -or $manifest.signature -ne 'unsigned'){throw 'EXE manifest mismatch'}
 $bom=Get-Content -LiteralPath ($zips[0].FullName -replace '\.zip$','.cdx.json') -Raw|ConvertFrom-Json
 if($bom.bomFormat -ne 'CycloneDX' -or $bom.specVersion -ne '1.6' -or $bom.metadata.component.version -ne $manifest.version -or $bom.metadata.component.hashes[0].content -cne $hash){throw 'SBOM mismatch'}
}finally{$zip.Dispose()}
Write-Host 'PASS checksums, package allowlist, executable hash, manifest and CycloneDX inventory'
