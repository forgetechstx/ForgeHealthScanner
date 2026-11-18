# Code signing policy

ForgeHealthScanner is a Forge Technologies project maintained by
[`forgetechstx`](https://github.com/forgetechstx).

## Status

Current releases are **unsigned**. No SignPath acceptance, sponsorship or
certificate is claimed. The proposed arrangement after acceptance would be
"Free code signing provided by SignPath.io, certificate by SignPath Foundation".
This wording describes a future proposal, not an existing service for this project.

## Roles and manual approval

- Author / maintainer: forgetechstx.
- Reviewer of outside contributions and release changes: forgetechstx.
- Release-signing approver: forgetechstx.

Each production signing request requires manual approval by forgetechstx after
review of the source revision, passing CI, package contents, SBOM and checksums.
Only artifacts built from this project's reviewed source in GitHub Actions may
be submitted. No signing job is enabled before provider acceptance/onboarding.
Outside contributions require maintainer review, including workflow changes.

GitHub and SignPath MFA are required before onboarding. This document does not
assert that MFA has been configured or independently verified. Keys must remain
with the provider; never create, export or commit release private keys/PFX files.
Any future service credentials belong in protected CI secrets, never source/logs.

Authenticode status must be checked on the actual downloaded EXE. Label it signed
only if its expected publisher and trusted certificate chain validate. SignPath
Foundation would be the publisher under that program, not Forge Technologies.
Signing does not guarantee immediate SmartScreen reputation.

[Privacy policy](PRIVACY.md) · [Official requirements](https://signpath.org/terms)
