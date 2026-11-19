# Release signing material

OwnTone Remote release APKs are signed with a **dedicated keystore** —
never the Android debug key, never the machine's `~/.android/debug.keystore`.

| Item | Location |
|---|---|
| Keystore (local, gitignored) | `android/owntone-release.keystore` |
| Passwords/config (local, gitignored) | `android/keystore.properties` |
| **Backup** (Actions secrets on this repo) | `RELEASE_KEYSTORE_B64`, `RELEASE_KEYSTORE_PASSWORD`, `RELEASE_KEY_PASSWORD` |
| Maintainer's own copy | off-machine, at the maintainer's discretion — **make one** |
| Public integrity anchor | `tools/keystore/checksum.sha256` (this repo) |

`release.sh` refuses to publish when the local material is missing or when
the built APKs are not signed by this key (`tools/keystore/verify.sh` is the
same check standalone). `android/app/build.gradle.kts` falls back to debug
signing only when the material is absent — that fallback keeps CI and fresh
clones building but can never publish, because of the `release.sh` checks.

## Backup policy (user decision, 2026-11-18)

The backup is **GitHub Actions secrets on this repo** — never a separate
repository (agents are barred from creating repos; ask the user instead).
Stored via:

```sh
base64 -i android/owntone-release.keystore | gh secret set RELEASE_KEYSTORE_B64
awk -F= '/^storePassword/{print $2}' android/keystore.properties | gh secret set RELEASE_KEYSTORE_PASSWORD
awk -F= '/^keyPassword/{print $2}'   android/keystore.properties | gh secret set RELEASE_KEY_PASSWORD
```

One documented property of secrets, stated once so it is never assumed
away: they are **write-only** (`gh secret list` shows names, never values).
That makes them usable by workflows and not readable back by anyone —
including you, at a terminal. A workflow signs by writing them to disk:

```yaml
- run: |
    echo "${{ secrets.RELEASE_KEYSTORE_B64 }}" | base64 -d > android/owntone-release.keystore
    printf 'storeFile=owntone-release.keystore\nstorePassword=%s\nkeyAlias=owntone-remote\nkeyPassword=%s\n' \
      "${{ secrets.RELEASE_KEYSTORE_PASSWORD }}" "${{ secrets.RELEASE_KEY_PASSWORD }}" > android/keystore.properties
    chmod 600 android/keystore.properties
```

**Therefore: keep your own off-machine copy of the two `android/` files.**
The secrets let CI (or a future release workflow) sign without the local
machine; they are not a `cp`-back restore path. Your own copy is.

## Restore (new machine / after loss)

From your own off-machine copy:

```sh
cp <your-backup>/owntone-release.keystore android/
cp <your-backup>/keystore.properties      android/
chmod 600 android/owntone-release.keystore android/keystore.properties
tools/keystore/verify.sh                    # must match the public checksum
```

If every copy is gone: the signing key is unrecoverable — the app
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
