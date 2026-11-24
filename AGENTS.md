# Project work instructions

Read [README](README.md) and [release preparation](docs/RELEASING.md) before changing installation, permissions or distribution. The current environment's global instructions supply the shared release policy; do not copy private policy locations into this repository.

- Preserve existing work and record exact changed files. Do not activate a receiver, modify Startup entries, inject keys, connect to a user's Android device or alter a firewall merely to check documentation.
- Host scripts remain ASCII-compatible with Windows PowerShell 5.1. Keep ownership checks in the shared helper; a port number or process name is insufficient evidence.
- Use `test/ReceiverIdentityTest.ps1` in a fresh process for ownership changes. Its fixture remains a self-owned sleeping process, with no UDP listener or keyboard activity. Only dispose or stop exact resources created by the test.
- Keep Android settings, device addresses, packet logs, screenshots and user data out of public examples. Use synthetic values and placeholders. Actual diagnostic output requires redaction before sharing.
- The paired UDP protocol covers sender and receiver, encryption, authenticated challenge and replay rejection. Keep the plaintext compatibility path closed and run the cross-runtime loopback test after changes to pairing or packet parsing.
- The debug signing setup is not a private production identity. Do not rotate keys, replace published assets or imply production authenticity without an approved plan.
- Record source/candidate identities, checks, unverified surfaces and rollback constraints. A syntax check or historical device test does not authorize publication.
