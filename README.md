<p align="center">
  <img src="docs/icon.png" width="160" alt="WA Classic">
</p>

<h1 align="center">WA Classic</h1>

<p align="center">
  <a href="https://waclassic.com"><img src="https://img.shields.io/badge/website-waclassic.com-2E9E3F?logo=safari&logoColor=white" alt="Website"></a>
  <a href="https://guide.waclassic.com"><img src="https://img.shields.io/badge/guide-guide.waclassic.com-2E9E3F?logo=readthedocs&logoColor=white" alt="Guide"></a>
  <a href="http://cydia.waclassic.com"><img src="https://img.shields.io/badge/Cydia-cydia.waclassic.com-8A5A2B" alt="Cydia source"></a>
  <a href="https://waclassic.com/devices"><img src="https://img.shields.io/badge/iOS-4_|_5_|_6-555555?logo=apple&logoColor=white" alt="iOS 4, 5, 6"></a>
  <a href="https://guide.waclassic.com/installing-the-bridge"><img src="https://img.shields.io/badge/bridge-Docker-2496ED?logo=docker&logoColor=white" alt="Bridge: Docker"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="License GPL-3.0"></a>
</p>

An unofficial WhatsApp client for jailbroken iPhones and iPod touches with iOS 4, 5 and 6, in the look of WhatsApp 2.10.

A small program, the **bridge**, runs on a computer in your home and is linked to your account as a linked device, like WhatsApp Web. The iPhone only talks to your bridge. Your phone stays the main device.

## Links

| | |
| --- | --- |
| Website | [waclassic.com](https://waclassic.com): features, devices, screenshots |
| Guide | [guide.waclassic.com](https://guide.waclassic.com): setup, using the app, differences to WhatsApp, troubleshooting and FAQ |
| Cydia source | `http://cydia.waclassic.com/` |
| Help | [Troubleshooting](https://guide.waclassic.com/troubleshooting), [FAQ](https://guide.waclassic.com/faq), [issues](https://github.com/aronsz26/WAClassic/issues) |

## Setup in short

1. **Start the bridge** on a Mac, Windows PC, Raspberry Pi or NAS with Docker:
   ```
   docker run -d --name wa-classic --restart unless-stopped -p 8097:8097 -p 25567:25567 -v wa-classic-data:/data ghcr.io/aronsz26/wa-classic-bridge:latest
   ```
2. **Open the setup page** at `http://localhost:8097`, choose a password. It shows the bridge's address and a setup code.
3. **Install WA Classic** in Cydia from `http://cydia.waclassic.com/` (Cydia picks the build for your iOS).
4. **Link WhatsApp:** open WA Classic, enter the address and code, scan the QR code with WhatsApp on your phone (Settings › Linked Devices).

The [guide](https://guide.waclassic.com) has the details for each computer, using WA Classic away from home, updating and removing.

## Devices

| Device | iOS | Package |
| --- | --- | --- |
| iPhone 3GS | 4.3 to 6 | the one for its iOS |
| iPhone 4 | 4.3 to 6 | the one for its iOS |
| iPhone 4S | 5.1.1 or 6 | the one for its iOS |
| iPhone 5 | 6 | WA Classic |
| iPod touch 3rd and 4th generation | 4.3 to 5.1.1 | WA Classic for iOS 4 and 5 |
| iPod touch 4th and 5th generation | 6 | WA Classic |

On an iPod touch everything works over Wi-Fi; the 3rd generation needs a headset with a microphone for calls and voice messages. The 8 GB iPod touch sold as 3rd generation (MC086) is a 2nd generation inside and stops at iOS 4.2.1, so it isn't supported. A version for iOS 7 to 10, in the look of WhatsApp 2.18, is coming later. The bridge already serves both looks.

> WA Classic is not affiliated with, endorsed by or connected to WhatsApp or Meta. Using an unofficial client may break WhatsApp's terms of service, and your account could be banned. Messages are stored unencrypted on the computer that runs the bridge.

## Building

The bridge (Go):
```
cd bridge
./patches/prepare.sh
go build -o build/wa4s-bridge .
```
or as an image: `docker build -t wa-classic-bridge bridge`. `-demo` starts it with made-up chats, for screenshots.

The app: `tools/build-app.sh` (armv7, iOS 9.3 SDK, needs `ldid`), `IOS4=1 tools/build-app.sh` for iOS 4 and 5.

The websites (waclassic.com, guide.waclassic.com and the Cydia source cydia.waclassic.com) are kept in their own repository.

## License

GPL-3.0, see [LICENSE](LICENSE). Built on [whatsmeow](https://github.com/tulir/whatsmeow), [hypermeow](https://github.com/polymorfa/hypermeow), [meowcaller](https://github.com/purpshell/meowcaller), [libsignal-protocol-go](https://github.com/polymorfa/libsignal-protocol-go), [go-qrcode](https://github.com/skip2/go-qrcode) and [FFmpeg](https://ffmpeg.org).

WhatsApp is a trademark of WhatsApp LLC.
