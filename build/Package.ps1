param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root 'dist'}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$exe=Join-Path $root 'HealthScan.exe'
$info=[Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
$version=([version]$info.FileVersion).ToString(3)
$stem="ForgeHealthScanner-$version-portable-unsigned"
if($info.ProductName -ne 'ForgeHealthScanner' -or $info.CompanyName -ne 'Forge Technologies'){throw 'Wrong product metadata'}
$sig=Get-AuthenticodeSignature -LiteralPath $exe
if($sig.Status -ne 'NotSigned'){throw "Unsigned packaging expects NotSigned, found $($sig.Status)"}
$zip=Join-Path $OutputDirectory ($stem+'.zip')
if(Test-Path -LiteralPath $zip){Remove-Item -LiteralPath $zip}
$archive=[IO.Compression.ZipFile]::Open($zip,[IO.Compression.ZipArchiveMode]::Create)
try {foreach($name in 'HealthScan.exe','README.md','README.txt','LICENSE','PRIVACY.md','CODE-SIGNING.md','THIRD-PARTY-NOTICES.md'){
 [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,(Join-Path $root $name),$name,[IO.Compression.CompressionLevel]::Optimal)
}}finally{$archive.Dispose()}
$asm=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe))
$components=@()
foreach($ref in $asm.GetReferencedAssemblies()){
 $components+=@{type='library';'bom-ref'=('system:'+ $ref.Name);name=$ref.Name;version=$ref.Version.ToString();scope='required';properties=@(@{name='forge:distribution';value='Windows system prerequisite; not bundled'})}
}
foreach($name in 'Collect-Health.ps1','RegistryCleaner.ps1','index.html','build/HealthScan.cs','build/RegistryAtomic.cs'){
 $components+=@{type='file';'bom-ref'=('source:'+$name);name=$name;version=$version;licenses=@(@{license=@{id='MIT'}});hashes=@(@{alg='SHA-256';content=(Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash.ToLowerInvariant()})}
}
$sbom=[ordered]@{bomFormat='CycloneDX';specVersion='1.6';serialNumber=('urn:uuid:'+[guid]::NewGuid());version=1;metadata=@{timestamp=[DateTime]::UtcNow.ToString('o');component=@{type='application';'bom-ref'='ForgeHealthScanner';name='ForgeHealthScanner';version=$version;licenses=@(@{license=@{id='MIT'}});hashes=@(@{alg='SHA-256';content=(Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()})}};components=$components}
$utf8=New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $OutputDirectory ($stem+'.cdx.json')),($sbom|ConvertTo-Json -Depth 15),$utf8)
$revision=(& git -C $root rev-parse HEAD | Out-String).Trim()
$manifest=@{product='ForgeHealthScanner';brand='Forge Technologies';maintainer='forgetechstx';version=$version;signature='unsigned';sourceRevision=$revision;os=[Environment]::OSVersion.Version.ToString();powershell=$PSVersionTable.PSVersion.ToString();compiler=(Get-Item "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe").VersionInfo.FileVersion;runtimeAssemblies=@($asm.GetReferencedAssemblies()|ForEach-Object {$_.FullName});executableSHA256=(Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()}
[IO.File]::WriteAllText((Join-Path $OutputDirectory ($stem+'.manifest.json')),($manifest|ConvertTo-Json -Depth 8),$utf8)
$lines=@();foreach($suffix in '.zip','.cdx.json','.manifest.json'){$name=$stem+$suffix;$lines+=((Get-FileHash -LiteralPath (Join-Path $OutputDirectory $name) -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+$name)}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS.txt'),(($lines -join "`n")+"`n"),$utf8)
& (Join-Path $PSScriptRoot 'Test-Package.ps1') -Directory $OutputDirectory
Write-Host "Packaged $stem; NotSigned verified."
