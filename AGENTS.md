# Spicewave

- `web/` is one page used twice: served by the Mac app (`main.swift`, http, key in the link) and by the site.
- Site: `bps.basilev.com`, Cloudflare Worker `spicewave`, mode Public, deployed from the Mac with `npm run deploy`. Local: `npm run dev` (port 8788). `.env.op` holds 1Password references only.
- `src/worker.js` only passes WebRTC set-up messages between devices of one room (a Durable Object). No sound, settings or logs are stored.
- App: `./build.sh`, then restart it (`open -g ~/Applications/Spicewave.app --args --quiet` starts it without opening the browser). The bundle id stays `com.basilev.butterchurn` so saved favorites, the key and the audio permission survive.
- Test in an invisible browser, never in windows on screen.
