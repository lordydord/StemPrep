# Security Policy

## Reporting a vulnerability

Please do not post API tokens, private audio or security-sensitive details in a public issue.

Use the repository's private **Report a vulnerability** option under the Security tab. Include the affected version, reproduction steps and impact. A maintainer will acknowledge the report before discussing a public fix.

## Credential handling

StemPrep stores the MVSEP API token in macOS Keychain. The token must never be committed to this repository, attached to an issue or included in a diagnostic log.
