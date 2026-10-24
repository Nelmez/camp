# Camp

Camp is a native macOS control panel and local web stack inspired by XAMPP. It manages Apache HTTP Server, PHP, MariaDB, Perl, ProFTPD, and phpMyAdmin as separate processes. Camp targets macOS 14 and newer on Apple silicon Macs (M1 and later).

## Build the app

From this directory:

```sh
./scripts/bundle-app.sh
```

The script creates `dist/Camp.app`. The app bundle includes the stack installer and configuration templates, so it can install the server stack after it is moved out of the source checkout. The build downloads pinned upstream source archives and compiles them locally on an Apple silicon Mac. Archive downloads are cached in `build/cache` for a source checkout or `~/Library/Caches/Camp/downloads` for a packaged app.

## Release package

Run `./scripts/package-installer.sh` on an Apple silicon Mac with Xcode command line tools, CMake, and valid Apple Developer ID Application and Developer ID Installer certificates installed. Set `CAMP_APP_SIGN_IDENTITY` and `CAMP_INSTALLER_SIGN_IDENTITY` to the exact certificate names shown by `security find-identity -v`. Create a notary profile with `xcrun notarytool store-credentials CampNotary --apple-id <Apple-ID> --team-id <Team-ID> --password <app-specific-password>`, then set `CAMP_NOTARY_PROFILE=CampNotary`. The script builds the arm64 server stack, signs `Camp.app` and the stack binaries, creates a signed `.pkg`, submits it for notarization, staples the ticket, and verifies the final package. The installer includes the prebuilt server stack and phpMyAdmin, so users do not need Xcode or CMake. The package installs Camp into `/Applications` and its immutable runtime under `/opt/camp`; server data and configuration remain under `/Library/Application Support/Camp`.

Without those credentials the release script stops before public packaging. Unsigned builds for local development can still be made with `./scripts/bundle-app.sh`. `./scripts/package-installer.sh --local-unsigned` creates an unsigned local `.pkg` preview that includes the prebuilt runtime. Run `./scripts/package-dmg.sh` to wrap that package in a `.dmg` with installation instructions and a package checksum. Both unsigned artifacts are previews: Gatekeeper may warn or block them, so they are not suitable for straightforward public distribution.

## Install and use

1. Open Camp from the installer. The installer places the arm64 server runtime at `/opt/camp` and phpMyAdmin in Camp's document root.
2. Start Apache, MariaDB, and ProFTPD from their sections or use **Start all**. Camp initializes service configuration and the database on first start.
3. Camp keeps mutable data, configuration, logs, and the web root under `/Library/Application Support/Camp`.
4. The default website is available at `http://127.0.0.1:8080/`; phpMyAdmin is at `/phpmyadmin/`.

Camp stores generated MariaDB and FTP credentials in the login Keychain. The initial credentials are displayed once after bootstrap. The default listeners are loopback only. Enabling all-interface binding exposes services to the local network. Camp uses ports above 1024 and runs its servers as your account; standard privileged ports are disabled in this release.

## Development commands

```sh
swift build -c debug
swift build -c release
```

The `Camp` executable also provides `status`, `bootstrap`, `rewrite`, `start`, `stop`, and `passwords` commands for local diagnostics and scripting.
