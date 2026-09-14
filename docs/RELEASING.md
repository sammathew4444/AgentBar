# Releasing AgentBar

AgentBar is published on GitHub for anyone who wants to try it. Releases are unsigned zips: no
Developer ID, no notarization, no App Store or Homebrew.

## Cutting a release

Push a version tag and CI does the rest: it runs the tests, builds a universal `AgentBar.app`
(Apple silicon and Intel) and attaches `AgentBar-<version>.zip` and its `.sha256` to a GitHub
release.

```sh
git tag v0.2.0 && git push origin v0.2.0
```

To build the same zip locally:

```sh
Scripts/release.sh 0.2.0   # writes dist/AgentBar-0.2.0.zip and dist/AgentBar-0.2.0.zip.sha256
```

## Opening a downloaded copy

Because the app isn't notarized, macOS quarantines a downloaded copy and refuses to open it the
first time. Either allow it once in System Settings › Privacy & Security › Open Anyway, or clear
the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/AgentBar.app
```
