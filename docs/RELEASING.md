# Build, release and verify

1. Review source and build/workflow changes. Confirm publication contains no live
   reports, private metadata, secrets or signing material. Run build/Test-Publication.ps1.
2. Update the collector, dashboard and assembly versions together; Build.ps1 rejects
   mismatches. Run Build.ps1 and Test-All.ps1 on Windows PowerShell 5.1 with Node.
3. Run Package.ps1. It creates a portable ZIP, CycloneDX JSON, manifest and SHA-256
   checksums. Test-Package.ps1 checks exact ZIP bytes, metadata and signature status.
4. Push the reviewed main branch and tag vX.Y.Z. The release workflow repeats build,
   tests and validation; only a successful build can publish the unsigned assets.
5. Enable GitHub Pages (Actions source). The Pages job deploys the static site.
   Check unauthenticated HTTP 200 for repo, homepage, privacy, signing policy,
   release and every asset. Download assets afresh and validate SHA-256 locally.
6. Before signing is enabled, obtain provider acceptance, configure MFA and protect
   approval credentials. Every signing request needs forgetechstx's manual approval.

Generated release assets are never committed as source. SHA-256 is computed after
final packaging; no subsequent line-ending conversion is allowed. Website files
have Git `-text` attributes and are checked against site-sha256.json after a fresh
clone/deployment. The source must pass byte-preservation checks before publishing.
Release private keys are never generated/exported here. Current status: unsigned.
