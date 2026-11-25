# Spicewave

Music visuals on any screen, with a pomodoro timer. Live at [bps.basilev.com](https://bps.basilev.com).

A browser cannot hear other apps on an iPad, so a computer supplies the sound:

- **PC, or a Mac with a recent Chrome:** open the site, press "Share this computer's sound", choose the entire screen and turn on system audio.
- **Mac app:** `./build.sh` installs `~/Applications/Spicewave.app` (macOS 14.4+, Apple silicon), which captures system audio with a Core Audio tap and opens the page on port 8787. Its signature is ad hoc, so macOS may ask for audio permission again after a rebuild.
- **iPad or any other device:** scan the code the computer shows. The sound goes straight between the two devices over an encrypted WebRTC connection; the site only introduces them. Keep the page open on the computer. Networks that block devices from reaching each other also block this.

The Mac app also serves the page on the local network without the internet; that link holds a key. Favorites, settings and the pomodoro timer are kept on the computer and shared with paired devices.

`web/` vendors butterchurn 2.6.7, butterchurn-presets 2.4.7 and qrcode-generator 1.4.4 (MIT, see `vendor-licenses/` and the file header).

The break picture, `web/meadow.jpg`, is drawn by `tools/meadow.html` (`tools/meadow.sh` renders it).
