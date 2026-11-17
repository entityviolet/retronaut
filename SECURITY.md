# Security policy

## Reporting

Do not open a public issue for a vulnerability. Use GitHub's *Report a
vulnerability* flow on this repository (Security tab), or contact the maintainers
privately.

Please include a minimal reproduction and the affected version.

## Scope

Retronaut executes untrusted input by design: game packs contain disk images,
executables and archives that the emulated machine runs. Reports are most useful
when they describe a path from a malicious **pack** or **store URL** to code
execution or file access **on the host device**, outside the emulated machine.

## Handling of credentials

The app stores no credentials. Signing identities and provisioning profiles are
build-host concerns and are deliberately excluded from this repository.
