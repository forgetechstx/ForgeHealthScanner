# Verified publishing status — 2026-11-18

ForgeHealthScanner 1.5.2 by Forge Technologies / forgetechstx is public and unsigned.
No SignPath approval, sponsorship, certificate or trusted signature is claimed.

## Verified links (unauthenticated HTTP 200)

- Repository: https://github.com/forgetechstx/ForgeHealthScanner
- Homepage/download: https://forgetechstx.github.io/ForgeHealthScanner/
- Privacy: https://forgetechstx.github.io/ForgeHealthScanner/privacy.html
- Code signing policy: https://forgetechstx.github.io/ForgeHealthScanner/code-signing.html
- Release: https://github.com/forgetechstx/ForgeHealthScanner/releases/tag/v1.5.2
- Application answers: https://github.com/forgetechstx/ForgeHealthScanner/blob/main/docs/SIGNPATH-APPLICATION.md
- Successful tagged build/release: https://github.com/forgetechstx/ForgeHealthScanner/actions/runs/44374598244
- Successful main build/Pages deployment: https://github.com/forgetechstx/ForgeHealthScanner/actions/runs/44374588836

## Engineering evidence

CI passed 84 collector, 46 battery/startup, 92 platform, 10 robustness, 21 launcher,
142 executable and 54 dashboard checks, plus disposable-key registry cleanup/undo,
external-process race protection, history bounds, fresh target rechecks, publication
and package validation. These are engineering checks, not independent adoption.
The Windows integration test ran a real read-only collector and fetched the
loopback dashboard; mocked platform tests are identified as mocks in CI output.
Release-only/Pages-only jobs skip on their opposite ref types by design.

The source revision in the downloaded release manifest is
`da1fd060ebdbcceed4575fa57a43e608cf1681b6`. The ZIP, SBOM, manifest and checksum
URLs returned HTTP 200. Independently downloaded files matched SHA256SUMS.txt;
the EXE matched both SBOM and manifest hashes. Downloaded Authenticode status was
NotSigned; product ForgeHealthScanner, company Forge Technologies, file version
1.5.2.0; `-Version` successfully reported 1.5.2. The downloaded SBOM validated
against the official CycloneDX 1.6 JSON schema.

A fresh GitHub clone preserved the checksummed website bytes, and independent
HTTP downloads of every deployed website file matched site/site-sha256.json.
No line-ending rewriting was applied to the published website assets.

## Release SHA-256

```
eb21dd6751c5d631ebc7bc038aeb9eedc5272cd8acdfdbc8f5d88eff866f10cb  ForgeHealthScanner-1.5.2-portable-unsigned.zip
9bd8db4d6e8414e9cefc28f8bd76a05dc5af7089a92c754a2a5f358151ac28e6  ForgeHealthScanner-1.5.2-portable-unsigned.cdx.json
bdbe7c0d67465c091a4cd30618502d95f312672eb368017b9f5ac47c8190f750  ForgeHealthScanner-1.5.2-portable-unsigned.manifest.json
```

## Remaining applicant-only steps

SignPath decides eligibility/reputation, including whether the disclosed local
security-status checks fall under its restricted tools policy. No established
widespread adoption is claimed. The applicant supplies personal contact details,
confirms legal status, enables/verifies GitHub and SignPath MFA, reviews legal and
privacy consent, and submits the application. No application was submitted here.
No release private keys were created, exported or committed.

Original local Git history was preserved privately; the public repository starts
with a reviewed snapshot attributed to forgetechstx. The working publication
checkout is separate from the original local repository, preventing accidental
publication of its personal author metadata. No user reports, history, backups,
settings or registry entries were removed by publication preparation.
