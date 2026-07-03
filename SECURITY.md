# Security Policy

The Rayls Network team takes the security of the protocol and its users seriously.
We are grateful to the security researchers and node operators who help keep the network safe.

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues, pull requests, or Discord.**

Report vulnerabilities privately through **GitHub's private vulnerability reporting**:

1. Open the [Security tab](https://github.com/raylsnetwork/axyl/security) of this repository.
2. Click **"Report a vulnerability"** and complete the advisory form.

This opens a channel visible only to the maintainers. If you are unable to use GitHub's
private reporting, contact a maintainer via the
[Rayls Network Discord](https://discord.com/channels/1252990258514235544/1252996402942836857)
to arrange a secure disclosure channel — do **not** include vulnerability details in public messages.

Where possible, please include:

- A description of the vulnerability and its potential impact.
- Steps to reproduce, or a proof of concept.
- The affected component(s), version(s), and configuration.
- Any suggested remediation.

## Response Process

1. We will acknowledge receipt of your report within **48 hours**.
2. We will provide an initial assessment within **5 business days**.
3. We will keep you informed of our progress as we investigate and resolve the issue.
4. Once resolved, we will notify you and coordinate public disclosure timing.

## Scope

| In-Scope  | Out-of-Scope |
|-----------|--------------|
| Core protocol code (this repo) | 3rd-party forks/dApps |
| Rayls Smart Contracts   | Non-official integrations |

### Out of Scope
- Already reported vulnerabilities.
- Vulnerabilities in dependencies (report to the dependency maintainer; we track dependency advisories via `cargo-deny` and Trivy).
- Theoretical vulnerabilities without a proof of concept.
- Social engineering attacks.

## Disclosure Policy

- All vulnerability reports and associated communications are treated as confidential.
- We kindly ask that you **not publicly disclose** any details until we have released a fix and agreed on a disclosure timeline.
- We aim to fix critical vulnerabilities as quickly as possible.
- We may provide pre-disclosure to key partners and node operators to ensure network stability.

## Bug Bounty

Rayls Network does **not currently operate a public bug-bounty program**. We still greatly
value responsible disclosure and are happy to provide recognition for valid reports (see
Credits below). This section will be updated if a program is launched.

## Security Audits

The Rayls Network protocol has undergone a third-party security audit by **Halborn**.
Remediated findings are recorded in [CHANGELOG.md](./CHANGELOG.md) under the
"Security Fixes (Halborn Audit)" entries. Contact the maintainers for audit details.

## Supported Versions

Rayls Network is under active development. Security fixes are released against the
**latest stable release**; node operators are strongly encouraged to always run the latest release.

| Version | Supported          |
|---------|--------------------|
| 1.1.x   | :white_check_mark: |
| < 1.1   | :x:                |

## Credits & Acknowledgments

We thank all security researchers who responsibly disclose vulnerabilities. If you wish to
receive credit for a valid report, let us know and we will acknowledge your contribution.
Your support is critical to keeping our protocol safe for the community.
