Universal app (Apple silicon and Intel), macOS 14 or later.

**Unverified developer.** The app is ad-hoc signed and not notarized, because I'm not paying Apple $99 a year for a side project, so macOS blocks the first open. Move the app to Applications, open it once, then go to **System Settings → Privacy & Security → Open Anyway**. Or run `xattr -dr com.apple.quarantine AgentAwake.app`. To avoid trusting a binary, build from source with `./build.sh`.
