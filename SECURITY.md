# Security

Report vulnerabilities through a private GitHub security advisory. Do not put
credentials, exploit details, or unredacted scanner output in a public issue.

API keys, webhook secrets, Vault tokens, and environment files must never be
committed. Dune build directories and trace files are ignored because build
traces may capture process environment values.

Before a push, install the configured pre-commit hook:

```sh
pre-commit install
```

Or run Gitleaks 8.30.1 directly:

```sh
gitleaks git --redact --verbose .
gitleaks dir --redact --verbose .
```

If a real credential reaches Git history, revoke or rotate it first. Removing a
file or force-pushing a clean branch does not invalidate the credential and may
leave the old commit available through cached GitHub views. Follow GitHub's
sensitive-data removal process and request server-side cache/reference purging
when the old object remains accessible.
