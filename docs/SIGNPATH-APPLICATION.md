# SignPath Foundation application draft

Owner/maintainer: forgetechstx. Brand: Forge Technologies. Status: unsigned;
not accepted or sponsored by SignPath. Public links, release downloads and CI were verified; see
[verification evidence](PUBLISHING-STATUS.md). This file is copy-ready text, not consent.

| Field | Answer |
| --- | --- |
| Project name | ForgeHealthScanner |
| Repository | https://github.com/forgetechstx/ForgeHealthScanner |
| Homepage / download | https://forgetechstx.github.io/ForgeHealthScanner/ |
| Privacy policy | https://forgetechstx.github.io/ForgeHealthScanner/privacy.html |
| Code signing policy | https://forgetechstx.github.io/ForgeHealthScanner/code-signing.html |
| License | MIT, no commercial dual licensing |
| Category | System Utilities, or Other if that is the available choice |
| Tagline | Portable local Windows health checks with review before startup cleanup. |
| Wikipedia | Leave blank; none established. |
| Build system | GitHub Actions on Windows; built-in C# compiler/PowerShell; pinned actions and Node; meaningful regression and portable-binary tests; package/checksum/SBOM validation. |
| Team | forgetechstx is author, maintainer, reviewer and manual release-signing approver. |
| Contact name/email | Applicant must supply personally. |
| Company/legal status | Forge Technologies is the brand; applicant must confirm legal organization/type. |
| Discovery channel | Applicant must state the actual source; do not invent it. |

## Project description

ForgeHealthScanner is a portable Windows 10/11 utility maintained by forgetechstx
under the Forge Technologies brand. It reads local storage, battery, Windows Update
cache, protection/configuration status and selected stability-event summaries, then
displays a local browser dashboard. It offers progress/cancellation and per-scan
opt-in local JSON history. Optional Microsoft Defender quick scanning is explicit.
Optional missing per-user startup cleanup requires selection and confirmation,
backs up the Run key, rechecks candidates and uses transactional changes. Undo
skips existing values. There is no installer, service, startup task, telemetry,
remote port scanning, exploit probing or report upload to the project.

Security-related status checks are present. Please assess them against your
restriction on vulnerability-diagnosis tools; we do not assume eligibility.

## Adoption and engineering evidence

This is a newly public project, with no verified widespread adoption, independent
endorsements or established download figures. Its prior local development and
regression tests demonstrate engineering effort, not community reputation.
Evidence for review is the MIT source, build workflow, passing public CI when
available, privacy/publication review, portable release, checksums and SBOM.

- CI: https://github.com/forgetechstx/ForgeHealthScanner/actions
- Release: https://github.com/forgetechstx/ForgeHealthScanner/releases/tag/v1.5.2
- Review: https://github.com/forgetechstx/ForgeHealthScanner/blob/main/docs/PUBLICATION-REVIEW.md
- Dependencies: https://github.com/forgetechstx/ForgeHealthScanner/blob/main/THIRD-PARTY-NOTICES.md

## Applicant-only steps

Verify these public URLs and CI first. Supply contact details; confirm legal status;
configure GitHub and SignPath MFA; read/accept applicable legal/privacy terms; make
the actual application submission. Marketing consent is optional. No MFA or legal
consent is asserted by this document. After acceptance, enforce manual signing
approval and verify trusted signatures before changing the unsigned labels.
