# AppMeta Build

Independent macOS app for Xcode Archive → manual-signed IPA export → App Store Connect upload.

Independent macOS app. It does **not** depend on [appmeta-local](https://github.com/dotcn999/appmeta-local).

## Website

- 推广站（Cloudflare Workers）：https://appmeta-build.findo.workers.dev  
- macOS 下载：https://github.com/dotcn999/appmeta-build/releases/latest  

## Open in Xcode

1. Double-click `AppMetaBuild.xcodeproj`, or:
   ```bash
   open AppMetaBuild.xcodeproj
   ```
2. Select the **AppMetaBuild** target → **Signing & Capabilities**.
3. Choose your **Team**. Leave App Sandbox **off** (the app must run `xcodebuild` and read provisioning profiles).
4. Pick the **AppMetaBuild** scheme → My Mac → Run.

## What to configure once

| Item | Where |
|---|---|
| Signing Team | Target → Signing & Capabilities |
| Bundle ID | default `io.appmeta.build` (change if you like) |
| App icon | `AppMetaBuild/Assets.xcassets/AppIcon` |
| Marketing version | Target → General → Version (`1.1.0`) |

In the running app, save **Key ID**, **Issuer ID**, and the `.p8`. They are stored under `~/Library/Application Support/AppMeta Build`, not AppMeta Local.

## Build a .app from the command line

```bash
xcodebuild -project AppMetaBuild.xcodeproj -scheme AppMetaBuild -configuration Release
```

