# Camp

A lightweight, native macOS control panel and local web development stack inspired by XAMPP. Built specifically for Apple Silicon and macOS 14+.

Camp packages and manages Apache HTTP Server, PHP, MariaDB, Perl, ProFTPD, and phpMyAdmin as isolated, user-space processes—no root privileges required.

---

## Features

- **Native macOS Experience:** Clean SwiftUI control panel to start, stop, and monitor services individually or all at once.
- **Complete Stack:**
  - **Apache 2.4** (with SSL support)
  - **PHP 8**
  - **MariaDB**
  - **Perl**
  - **ProFTPD**
  - **phpMyAdmin** (pre-installed and pre-configured)
- **User-Space & Rootless:** Operates entirely on user ports (> 1024) without requiring `sudo` or modifying system directories.
- **Zero-Config Bootstrap:** Automatically creates configurations, bootstraps databases, and provisions secure credentials stored in macOS Keychain on first launch.
- **Built-in CLI:** Script and control services directly from the terminal via `Camp` / `campctl`.
- **Sparkle Updates:** Built-in seamless update delivery.

---

## Quick Start

### Installation

1. Download the latest release (`Camp.dmg`) from [Releases](https://github.com/Nelmez/camp/releases).
2. Open the disk image and install **Camp**.
3. Launch **Camp** from `/Applications`.

### Default Services & Endpoints

| Service | Protocol / Port | Local URL / Access |
|---|---|---|
| **Web Server (Apache)** | HTTP `8080` / HTTPS `8443` | `http://127.0.0.1:8080/` |
| **phpMyAdmin** | Web | `http://127.0.0.1:8080/phpmyadmin/` |
| **MariaDB** | MySQL `3306` | `127.0.0.1:3306` |
| **FTP (ProFTPD)** | FTP `2121` | `127.0.0.1:2121` |

> Generated credentials for MariaDB and FTP are saved securely in your macOS Keychain and displayed after initial bootstrap.

---

## File Layout

Camp separates immutable application binaries from mutable user project data:

- **Application:** `/Applications/Camp.app`
- **Runtime & Binaries:** `/opt/camp/`
- **Document Root (htdocs):** `/Library/Application Support/Camp/htdocs`
- **Configuration:** `/Library/Application Support/Camp/conf`
- **Logs:** `/Library/Application Support/Camp/logs`
- **Database Data:** `/Library/Application Support/Camp/mysql`

---

## Command Line Interface

The `Camp` binary can be run from the command line for automation, status checks, and scripting:

```sh
# Check service status and runtime versions
Camp status

# Start or stop services (individual or all)
Camp start [apache|mariadb|proftpd|all]
Camp stop [apache|mariadb|proftpd|all]

# Retrieve stored credentials from Keychain
Camp passwords

# Re-generate configuration files
Camp rewrite
```

---

## Building from Source

### Prerequisites

- Apple Silicon Mac running macOS 14 Sonoma or newer
- Xcode Command Line Tools (`xcode-select --install`)
- CMake (`brew install cmake`)

### Build Steps

Clone the repository and compile the stack:

```sh
git clone https://github.com/Nelmez/camp.git
cd camp

# Build the complete Camp.app bundle (compiles stack and app)
./scripts/bundle-app.sh

# Or build Swift targets directly
swift build -c release
```

To create an unsigned local installer package and DMG preview:

```sh
./scripts/package-installer.sh --local-unsigned
./scripts/package-dmg.sh --local-unsigned
```

---

## License

Camp is open source licensed under the [MIT License](LICENSE).
