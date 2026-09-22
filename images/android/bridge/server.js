#!/usr/bin/env node
/*
 * easyworker Android screen bridge (X11-free, view-only).
 *
 * Runs the official Android emulator headless (-no-window) and relays its
 * screen to a browser. Video comes from scrcpy-server over adb forward:
 *
 *   adb forward tcp:VPORT localabstract:scrcpy_<scid>
 *   video socket: [1 dummy][64 name][4 codec][12 session meta]
 *                 then packets [8 pts|flags][4 size][size bytes Annex-B H.264]
 *
 * The access units are forwarded over a WebSocket and decoded by WebCodecs.
 *
 * There is deliberately NO input endpoint: the screen is view-only. To drive
 * the device, run adb through easyworker's own API, e.g.
 *
 *   easyworker Execute: adb -s emulator-5554 shell input tap 540 1200
 *                       adb -s emulator-5554 shell input text hello
 *
 * Endpoints:
 *   GET /        -> player page
 *   GET /healthz -> 200 while the bridge is up
 *   WS  /h264    -> Annex-B H.264 access units (1 byte tag: 0 delta, 1 key, 2 config)
 */
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const net = require('net');
const { spawn } = require('child_process');
const { WebSocketServer } = require('ws');

const PORT = parseInt(process.env.PORT || '6080', 10);
const ADB = process.env.ADB || 'adb';
const SERIAL = process.env.ANDROID_SERIAL || 'emulator-5554';
const SERVER_JAR = process.env.SCRCPY_SERVER || '/opt/scrcpy-server.jar';
const SCRCPY_VERSION = process.env.SCRCPY_VERSION || '4.1';
const VPORT = parseInt(process.env.SCRCPY_PORT || '27183', 10);
const SCID = process.env.SCRCPY_SCID || '0000beef';
const BITRATE = process.env.BITRATE || '8000000';
const MAXSIZE = process.env.MAXSIZE || '1080';
const MAXFPS = process.env.MAXFPS || '30';

const INDEX = path.join(__dirname, 'index.html');
const JMUXER = path.join(__dirname, 'jmuxer.min.js');
const log = (...a) => console.log(new Date().toISOString(), ...a);

function adb(args, opts) { return spawn(ADB, ['-s', SERIAL, ...args], opts); }

/* ---- scrcpy server lifecycle ---------------------------------------- */
let serverProc = null;
function startServer() {
  adb(['push', SERVER_JAR, '/data/local/tmp/scrcpy-server.jar']).on('close', () => {
    adb(['forward', '--remove-all']).on('close', () => {
      const args = ['CLASSPATH=/data/local/tmp/scrcpy-server.jar', 'app_process', '/',
        'com.genymobile.scrcpy.Server', SCRCPY_VERSION, `scid=${SCID}`, 'log_level=info',
        'audio=false', 'control=false', 'send_frame_meta=true', 'tunnel_forward=true',
        `max_size=${MAXSIZE}`, `max_fps=${MAXFPS}`, `video_bit_rate=${BITRATE}`];
      serverProc = adb(['shell', args.join(' ')]);
      serverProc.stdout.on('data', (d) => process.stdout.write('[scrcpy] ' + d));
      serverProc.stderr.on('data', (d) => process.stderr.write('[scrcpy] ' + d));
      serverProc.on('close', (c) => { log('scrcpy-server exited', c); serverProc = null; });
      setTimeout(() => {
        adb(['forward', `tcp:${VPORT}`, `localabstract:scrcpy_${SCID}`])
          .on('close', () => log('forward ready', VPORT));
      }, 2500);
    });
  });
}
function stopServer() { if (serverProc) { try { serverProc.kill('SIGKILL'); } catch (_) {} } }

/* ---- video socket reader -------------------------------------------- */
// One persistent buffer + waiter; every read shares a single 'data' handler so
// a chunk arriving mid-read cannot desync the stream.
class Reader {
  constructor(sock) {
    this.buf = Buffer.alloc(0);
    this.waiter = null;
    this.err = null;
    sock.on('data', (d) => { this.buf = Buffer.concat([this.buf, d]); this._wake(); });
    sock.on('error', (e) => { this.err = e; this._wake(); });
    sock.on('close', () => { this.err = this.err || new Error('closed'); this._wake(); });
  }
  _wake() { if (this.waiter) { const w = this.waiter; this.waiter = null; w(); } }
  read(n) {
    return new Promise((resolve, reject) => {
      const tryTake = () => {
        if (this.buf.length >= n) {
          const b = this.buf.subarray(0, n);
          this.buf = this.buf.subarray(n);
          return resolve(b);
        }
        if (this.err) return reject(this.err);
        this.waiter = tryTake;
      };
      tryTake();
    });
  }
}

// The last config (SPS/PPS) and keyframe seen, so a browser that connects
// later still gets a decodable stream (scrcpy emits an IDR only occasionally).
const prime = { config: null, key: null, meta: null };

async function attach(sock, send) {
  sock.setNoDelay(true);
  const r = new Reader(sock);
  await r.read(1);                               // dummy
  const name = (await r.read(64)).toString('utf8').replace(/\0.*$/, '');
  const codec = (await r.read(4)).toString('ascii');
  log('device:', name, 'codec:', codec);
  const meta = await r.read(12);
  const w = meta.readUInt32BE(4), h = meta.readUInt32BE(8);
  log('video', w + 'x' + h);
  prime.meta = JSON.stringify({ type: 'meta', codec, width: w, height: h });
  send(prime.meta);
  if (prime.config) send(prime.config);
  if (prime.key) send(prime.key);

  for (;;) {
    const hdr = await r.read(12);
    const ptsFlags = hdr.readBigUInt64BE(0);
    const size = hdr.readUInt32BE(8);
    const payload = await r.read(size);
    const key = (ptsFlags & (1n << 61n)) !== 0n;
    const cfg = (ptsFlags & (1n << 62n)) !== 0n;
    if (cfg) {
      const msg = Buffer.concat([Buffer.from([2]), payload]);
      prime.config = msg; send(msg);
    } else {
      const msg = Buffer.concat([Buffer.from([key ? 1 : 0]), payload]);
      if (key) prime.key = msg;
      send(msg);
    }
  }
}

/* ---- HTTP ----------------------------------------------------------- */
const server = http.createServer((req, res) => {
  if (req.url === '/' || req.url === '/index.html') {
    fs.readFile(INDEX, (e, b) => {
      if (e) { res.writeHead(500); return res.end('no index'); }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(b);
    });
    return;
  }
  if (req.url === '/jmuxer.min.js') {
    fs.readFile(JMUXER, (e, b) => {
      if (e) { res.writeHead(404); return res.end('no jmuxer'); }
      res.writeHead(200, { 'Content-Type': 'application/javascript' });
      res.end(b);
    });
    return;
  }
  if (req.url === '/healthz') { res.writeHead(200); return res.end('ok'); }
  res.writeHead(404); res.end('not found');
});

const wss = new WebSocketServer({ server, path: '/h264' });

// One upstream scrcpy connection, broadcast to every browser. scrcpy-server
// accepts a single connection (LocalServerSocket.accept()), so we must not
// open one per client.
const clients = new Set();
let upstream = null;
function broadcast(msg) { for (const ws of clients) if (ws.readyState === ws.OPEN) ws.send(msg); }

function connectUpstream() {
  if (upstream) return;
  const sock = net.createConnection({ host: '127.0.0.1', port: VPORT }, () => {
    upstream = sock;
    attach(sock, broadcast).catch((e) => {
      log('upstream ended:', e.message);
      upstream = null;
      setTimeout(connectUpstream, 1500);
    });
  });
  sock.on('error', () => { upstream = null; });
  sock.on('close', () => { if (upstream === sock) upstream = null; });
}

wss.on('connection', (ws) => {
  clients.add(ws);
  if (prime.meta) ws.send(prime.meta);
  if (prime.config) ws.send(prime.config);
  if (prime.key) ws.send(prime.key);
  connectUpstream();
  ws.on('close', () => clients.delete(ws));
  ws.on('error', () => clients.delete(ws));
});

server.listen(PORT, () => {
  log(`bridge listening on :${PORT} (serial=${SERIAL} vport=${VPORT})`);
  startServer();
});
process.on('SIGTERM', () => { stopServer(); process.exit(0); });
process.on('SIGINT', () => { stopServer(); process.exit(0); });
