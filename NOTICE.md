# Notices

Codex for ipad is an unofficial community project and is not affiliated with,
endorsed by, or sponsored by OpenAI.

Codex, ChatGPT, OpenAI, Apple, iPad, iCloud and other names or marks belong to
their respective owners.

The repository intentionally excludes official installers, extracted desktop
resources, signed application packages, credentials and signing identities.
Users supply third-party software locally and remain responsible for complying
with its license and terms.

Vendored or downloaded third-party dependencies retain their own licenses. In
particular, the optional iOS Python runtime is sourced from BeeWare's
Python-Apple-support project using the pinned metadata in
`CodexPad/Vendor/runtime-lock.json`.

The vendored `CodexCore/vendor/codex-utils-stream-parser` component is
licensed under Apache License 2.0. Its license text is retained beside the
component.

The test fixture `tests/fixtures/python-apple-utils.sh` is copied from the
pinned BeeWare Python-Apple-support runtime solely to verify the public build
contract. It remains covered by the upstream project's license.
