# Issues

Issues and improvement opportunities found while using MWT, one file each,
named for what is wrong, not for when it was found. Each file says when it
was found and with which version, its kind and status, what happens, the
evidence, and a fix or a workaround when one is known.

| Issue | Kind | Status |
| --- | --- | --- |
| [A file in the VM image reads as zeros after loading](vm-image-file-zeroed-after-load.md) | bug | cause unknown; MWT notices it since 2026-11-24 |
| [Workspace copy-back fails on every file](workspace-copy-back-fails.md) | bug | open |
| [The Home and Cache disks started empty after an update](home-and-cache-disks-emptied.md) | bug | to confirm |
| [A preset's icon shows as an empty box](preset-icon-missing-from-css.md) | bug | open |
| [A login refresh MWT answers itself still asks for approval](login-refresh-asks-for-approval.md) | improvement | resolved (2026-11-24) |
| [Google's token and signing hosts must be listed on every grant](google-endpoint-hosts-listed-by-hand.md) | improvement | resolved (2026-11-24) |
| [Grants built on the same login each mint their own copy](one-login-many-grants.md) | improvement | resolved (2026-11-24), ID token age apart still open |
| ["Allow similar" can't cover a REST resource with ids](allow-similar-by-route.md) | improvement | resolved (2026-11-24) |
| [A request subgrant can't send a signed JWT or an ID token](request-subgrant-signed-credentials.md) | improvement | resolved (2026-11-24) |
| [A login file names no project](login-file-without-project.md) | improvement | partly resolved (2026-11-24) |
| [No preset for a GitHub App installation token](github-app-preset.md) | improvement | resolved (2026-11-24) |
| ["Only that command gets it" reads as secrecy](placeholder-files-readable.md) | documentation | resolved (2026-11-24) |
| [`mwt run` arguments are expanded in the VM first](run-arguments-expand-in-vm.md) | documentation | fixed 2026-11-24 |
