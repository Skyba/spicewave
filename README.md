# Spicewave

Draws the sound this Mac is playing, in a browser on the Mac and on any device on the same network (made for the iPad).

`./build.sh` installs `~/Applications/Spicewave.app`. The app captures system audio (macOS 14.4+, Core Audio tap), serves the page on port 8787 and streams sound levels at 60 frames per second. Nothing is played or captured on the iPad. Favorites and settings are kept on the Mac and shared by every device; each device runs its own pomodoro timer. Opened without the app, the page can use a computer's own sound through the browser's share dialog. The link holds a key; without it the sound stream is refused. The app's signature is ad hoc, so macOS may ask for audio permission again after a rebuild.

`web/` vendors butterchurn 2.6.7 and butterchurn-presets 2.4.7 (MIT, see `vendor-licenses/`).
