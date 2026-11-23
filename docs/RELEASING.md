# Native release process

1. Build with `build/Build-Native.ps1` on Windows and run `build/Test-All.ps1` in Windows PowerShell 5.1. The native EXE is under `dist/native`.
2. Run `build/Package.ps1 -RequireCleanSource -OutputDirectory dist/release` in a fresh checkout with an empty staging directory. Packaging rebuilds the native EXE, validates its unsigned status, and generates the portable ZIP, build manifest, CycloneDX SBOM and SHA-256 checksums.
3. CI tests the same build, validates the version against the tag, and checks the four staged files. The release job revalidates the downloaded artifact and publishes only those files.
4. Keep version metadata, website download URLs, notes and website byte checksums in sync. The main-branch Pages deployment publishes the reviewed site. Verify anonymous access and SHA-256 after publication with `build/Verify-PublicRelease.py`.
5. Signing requires provider onboarding and manual approval by forgetechstx. See CODE-SIGNING.md.
