# Security Policy

## Reporting Security Issues

We take the security of `mapbox_nav_core` and its users seriously.

If you discover a security vulnerability, please **DO NOT** open a public GitHub issue.

Instead, please report security vulnerabilities responsibly by:
- Creating a **GitHub Private Vulnerability Report** via the "Security" tab of this repository.

Please include:
- A clear description of the vulnerability.
- Steps or a minimal reproduction snippet.
- The affected package version and platform (Android, iOS).

You will receive an acknowledgment within 48 hours, along with updates regarding patches and remediation.

---

## Token and Credential Security

- **Mapbox Tokens**: Mapbox public access tokens (`pk.*`) are intended for client-side rendering, but should be restricted by bundle ID / package name in your Mapbox account dashboard.
- **Secret Downloads Tokens (`sk.*`)**: Secret tokens used for downloading the Mapbox SDK must remain in private environment variables (e.g. `MAPBOX_DOWNLOADS_TOKEN`) and must never be committed to git repositories or checked into application code.
- Pull requests found to contain exposed credentials, API keys, or private access tokens will be closed immediately.
