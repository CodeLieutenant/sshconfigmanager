fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac setup_certs

```sh
[bundle exec] fastlane mac setup_certs
```

One-time (run locally): create & store ALL distribution identities

### mac build_appstore

```sh
[bundle exec] fastlane mac build_appstore
```

Build the signed Mac App Store .pkg

### mac beta

```sh
[bundle exec] fastlane mac beta
```

Build the MAS .pkg and upload it to TestFlight

### mac release_notes

```sh
[bundle exec] fastlane mac release_notes
```

Rewrite release_notes.txt from CHANGELOG.md (no build, no upload)

### mac precheck_only

```sh
[bundle exec] fastlane mac precheck_only
```

Run App Store metadata precheck only (diagnostic, no upload)

### mac release

```sh
[bundle exec] fastlane mac release
```

Build once, upload to TestFlight, deliver metadata and screenshots. submit:true submits for review

### mac release_upload

```sh
[bundle exec] fastlane mac release_upload
```

Re-upload the pkg already in build/ (no rebuild) after a transporter failure

### mac preview

```sh
[bundle exec] fastlane mac preview
```

Record the full-feature App Preview video and upload it to App Store Connect

### mac intellisense_demo

```sh
[bundle exec] fastlane mac intellisense_demo
```

Record the IntelliSense demo video and upload it to App Store Connect

### mac tunnel_demo

```sh
[bundle exec] fastlane mac tunnel_demo
```

Record the tunnel lifecycle demo video and upload it to App Store Connect

### mac upload_all_previews

```sh
[bundle exec] fastlane mac upload_all_previews
```

Upload all three App Preview videos to App Store Connect (record them first)

### mac screenshots

```sh
[bundle exec] fastlane mac screenshots
```

Capture App Store screenshots (UI test) and upload only the screenshots

### mac developerid

```sh
[bundle exec] fastlane mac developerid
```

Build, sign, notarize and package a Developer ID .dmg

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
