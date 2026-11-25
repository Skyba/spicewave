import { DurableObject } from 'cloudflare:workers';

// The Mac app's page (localhost:8787) and the site itself may signal; localhost:8788 is wrangler dev.
const ORIGINS = ['https://bps.basilev.com', 'http://localhost:8787', 'http://localhost:8788'];

export default {
  async fetch(req, env) {
    const m = new URL(req.url).pathname.match(/^\/signal\/([0-9a-f]{32})\/(send|receive)$/);
    if (!m) return new Response('Not found', { status: 404 });
    if (req.headers.get('Upgrade') !== 'websocket') return new Response('Expected a WebSocket', { status: 426 });
    if (!ORIGINS.includes(req.headers.get('Origin'))) return new Response('Forbidden', { status: 403 });
    return env.ROOM.get(env.ROOM.idFromName(m[1])).fetch(req);
  },
};

// Passes connection set-up messages between the devices of one room. Sound never goes through here,
// and nothing is stored.
export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }

  async fetch(req) {
    if (this.ctx.getWebSockets().length >= 16) return new Response('Room is full', { status: 429 });
    const role = new URL(req.url).pathname.endsWith('/send') ? 'send' : 'receive';
    const [client, server] = Object.values(new WebSocketPair());
    const id = crypto.randomUUID();
    this.ctx.acceptWebSocket(server, [role, id]);
    server.serializeAttachment({ id, role });
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws, raw) {
    if (typeof raw !== 'string' || raw.length > 20000) return;
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    if (!msg || typeof msg !== 'object') return;
    const { id, role } = ws.deserializeAttachment();
    const text = JSON.stringify({ ...msg, from: id });
    const others = this.ctx.getWebSockets(msg.to ? String(msg.to) : role === 'send' ? 'receive' : 'send');
    for (const o of others) if (o.deserializeAttachment().role !== role) try { o.send(text); } catch {}
  }

  webSocketClose(ws) { try { ws.close(); } catch {} }
  webSocketError(ws) { try { ws.close(); } catch {} }
}
