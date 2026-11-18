# Release signing material

OwnTone Remote release APKs are signed with a **dedicated keystore** —
never the Android debug key, never the machine's `~/.android/debug.keystore`.

| Item | Location |
|---|---|
| Keystore (local, gitignored) | `android/owntone-release.keystore` |
| Passwords/config (local, gitignored) | `android/keystore.properties` |
| **Escrow backup** (private repo) | <https://github.com/jptrsn/owntone_remote-private> — same two files + this restore doc |
| Public integrity anchor | `tools/keystore/checksum.sha256` (this repo) |

`release.sh` refuses to publish when the local material is missing or when
the built APKs are not signed by this key (`tools/keystore/verify.sh` is the
same check standalone). `android/app/build.gradle.kts` falls back to debug
signing only when the material is absent — that fallback keeps CI and fresh
clones building but can never publish, because of the `release.sh` checks.

## Why a private repo and not GitHub secrets?

Repo **secrets are write-only**: they are injected into workflow runs but
can never be read back (`gh secret list` shows names only). They are
therefore unusable as a backup — if this machine dies, a secret cannot
restore the signing key. A private sibling repo is restorable (`git clone`)
while staying out of the public repo. If CI ever needs to sign, read the
escrow repo from a workflow with a scoped fine-grained token rather than
copying the keystore into a secret.

## Restore (new machine / after loss)

```sh
git clone https://github.com/jptrsn/owntone_remote-private
cp owntone-remote-private/android/owntone-release.keystore android/
cp owntone-remote-private/android/keystore.properties      android/
chmod 600 android/owntone-release.keystore android/keystore.properties
tools/keystore/verify.sh                    # must match the public checksum
```

If the escrow repo is also gone: the signing key is unrecoverable — the app
ID survives but every future APK will have a new certificate, meaning all
existing installs (Obtainium) must uninstall and reinstall. Rotate
deliberately in that case and document it in the release notes.

## Emergency facts

- Keystore type PKCS12; **key password == store password** (PKCS12 does not
  support differing passwords — a differing `keyPassword` in the properties
  file is ignored by tooling but keep them equal).
- Alias `owntone-remote`, RSA 4096, self-signed, valid until **2056**.
- Certificate SHA-256 is the identity Obtainium compares on update. The
  v0.1.0 release was debug-signed; the first release built with this key
  requires a **one-time uninstall/reinstall** — say so in its release notes.
