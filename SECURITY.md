# Security Policy

EON handles accounts, and soon players' AI keys, so security reports are very welcome.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through
[GitHub's security advisory form](https://github.com/samim-reza/EON/security/advisories/new).

Include what you found, how to reproduce it, and what an attacker could do with it. You should get a reply
within a few days. We'll tell you when it's fixed and credit you unless you'd rather stay anonymous.

## What we care about most

- Anyone other than the one God gaining God powers, or skipping the MFA requirement
- Reading or changing data without permission, or bypassing row-level security
- Stealing sessions, or script injection
- Forging or altering the audit log
- Exposing secrets or, later, players' AI keys

## Testing rules

Please test against your own local copy: see [CONTRIBUTING.md](CONTRIBUTING.md) for setup.

On the live site, don't run load tests or scanners, don't touch accounts or data that aren't yours, and don't
disrupt the world. Good-faith research that follows these rules won't be held against you.

## Supported versions

Only the `main` branch, which is what's deployed, gets security fixes.
