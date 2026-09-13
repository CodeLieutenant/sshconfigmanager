# Releasing

The `Release` workflow in `.github/workflows/release.yml` builds the Mac App Store app, a notarized Developer ID `.dmg`, the Linux packages and a Flatpak bundle. A `v*` tag starts it. You can also start it manually.

## Secrets

Add each secret in the repository settings, under **Settings > Secrets and variables > Actions**. Never write a real value into a file in this repository.

| Secret | What it is | How to create it |
|---|---|---|
| `APPLE_TEAM_ID` | The 10-character Apple Developer team ID. | Open the Membership details page on developer.apple.com. Copy the Team ID. |
| `APP_IDENTIFIER` | The bundle ID of the Mac app. It must end in `.sshconfigmanager`. The workflow uses the part before that suffix as `BUNDLE_ID_PREFIX`. | Register the ID under Certificates, Identifiers & Profiles. Use your own reverse-DNS prefix. |
| `MATCH_GIT_URL` | The SSH URL of the private Git repository that holds the encrypted certificates and profiles. | Create an empty private repository. Copy its SSH clone URL. |
| `MATCH_PASSWORD` | The passphrase that encrypts the match repository. | Make a long random passphrase. Keep a copy in your password manager. |
| `MATCH_GIT_SSH_KEY` | The private half of a read-only deploy key for the match repository, in base64. | Run `ssh-keygen -t ed25519 -f match_key -N ""`. Add `match_key.pub` as a read-only deploy key. Run `base64 -i match_key` and copy the output. |
| `ASC_KEY_ID` | The ID of the App Store Connect API key. | Open Users and Access > Integrations in App Store Connect. Make a key with the App Manager role. Copy the Key ID. |
| `ASC_ISSUER_ID` | The issuer ID of your App Store Connect team. | Copy the Issuer ID from the same page. |
| `ASC_API_KEY_BASE64` | The `.p8` key file, in base64. | Download the `.p8` file. Run `base64 -i AuthKey_XXXX.p8` and copy the output. |
| `KEYCHAIN_PASSWORD` | The password of the temporary keychain on the runner. | Make a random string. |
| `GITHUB_GIST_CLIENT_ID` | The client ID of the GitHub OAuth app for Gist sync. | Create an OAuth app under GitHub Developer settings. Turn on device flow. Copy the Client ID. |
| `EXPORT_COMPLIANCE_CODE` | The export compliance code from App Store Connect. | Open App Information > App Encryption Documentation. Copy the code of the approved document. |

## First certificates

Do these steps one time, on a Mac, before the first release.

1. Create the empty private match repository.
2. Export `APPLE_TEAM_ID`, `APP_IDENTIFIER`, `MATCH_GIT_URL` and `MATCH_PASSWORD` in your shell.
3. Run `bundle install`.
4. Run `bundle exec fastlane mac setup_certs`.
5. Sign in with your Apple ID when fastlane asks.
6. Make sure that the match repository now holds encrypted files.

## First dry run

Do this dry run before you push the first tag.

1. Add all the secrets.
2. Open the **Actions** tab on GitHub.
3. Select the **Release** workflow.
4. Click **Run workflow**.
5. Set `testflight_only` to true.
6. Set `developer_id` to false.
7. Click **Run workflow** again to start the run.
8. Make sure that the `app-store` job uploads a build to TestFlight.
9. Make sure that App Store Connect shows the metadata and screenshots.
10. Make sure that the `linux-packages` job uploads a `.deb` and a `.rpm` for each architecture.
11. Make sure that the `flatpak` job uploads `sshconfigmanager.flatpak`.

Only a run from a `v*` tag creates a GitHub release.

## Release procedure

1. Write each change under `## [Unreleased]` in `CHANGELOG.md`.
2. Run `python3 scripts/changelog.py release X.Y.Z`.
3. Set `MARKETING_VERSION` to `X.Y.Z` in `sshconfigmanager.xcodeproj/project.pbxproj`.
4. Set `AppVersion.current` in the Linux app to `X.Y.Z`.
5. Increase `CURRENT_PROJECT_VERSION` by one.
6. Run `make changelog-check version-check`.
7. Commit the changes.
8. Push the commit to `main`.
9. Run `git tag vX.Y.Z`.
10. Run `git push origin vX.Y.Z`.
11. Open the **Release** workflow run on the **Actions** tab.
12. Make sure that every job completes.
13. Make sure that the GitHub release has the `.dmg`, the Linux packages and the Flatpak bundle.
14. Make sure that App Store Connect shows the version as waiting for review.

## Developer ID build

Each `v*` tag builds the `.dmg`. Use these steps to build it from a manual run.

1. Open the **Release** workflow on the **Actions** tab.
2. Click **Run workflow**.
3. Set `developer_id` to true.
4. Start the run.
5. Download the `macos-dmg` artifact from the run.

## Local release

The local lanes read the same variables as the workflow.

1. Put the variables in a `.release` file at the repository root.
2. Make sure that `.release` stays out of Git.
3. Run `./scripts/release.sh testflight` to upload a TestFlight build.
4. Run `./scripts/release.sh release` to upload a build and deliver the metadata.
