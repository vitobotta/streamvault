# Tailscale Proxy — VPS to Home

Proxy all traffic from a tiny VPS to your home computer via Tailscale. The VPS terminates TLS and handles incoming traffic from the internet; your home machine runs the Rails app + ffmpeg with an unrestricted residential IP for RealDebrid downloads.

## Why

- RealDebrid CDN blocks/rate-limits datacentre IPs (`X-Error: bytes_limit_reached`)
- Your home IP is residential — no bandwidth limit
- The VPS provides a stable public IP and TLS without Cloudflare's 100s timeout
- Tailscale connects them securely (WireGuard, no port forwarding needed)

## Architecture

```
Internet → VPS (public IP, Caddy, TLS) → Tailscale tunnel → Home (Rails + ffmpeg)
```

## Setup

### 1. Install Tailscale on both machines

```bash
# On the VPS and on your home computer:
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Verify they can see each other:
tailscale status
```

### 2. Get your home machine's Tailscale IP

```bash
# On your home computer:
tailscale ip -1
# → 100.x.x.x
```

### 3. DNS

Point an A record for your domain to the **VPS public IP**. Do NOT use Cloudflare proxying (grey cloud, DNS only).

### 4. Configure the Caddyfile

Edit `Caddyfile`:
- Replace `media.example.com` with your domain
- Replace `100.x.x.x:3000` with your home Tailscale IP + app port

### 5. Start Caddy on the VPS

```bash
cd tailscale-proxy
docker compose up -d
```

Caddy auto-provisions Let's Encrypt certificates.

### 6. Run the app on your home computer

```bash
# Bind to the Tailscale IP (not localhost) so Caddy can reach it
RAILS_ENV=production \
  DATABASE_URL="postgres://..." \
  SECRET_KEY_BASE="..." \
  RAILS_MASTER_KEY="..." \
  bin/rails server -b 100.x.x.x -p 3000
```

Or with Puma directly:
```bash
bundle exec puma -b tcp://100.x.x.x:3000
```

### 7. Access

Open `https://media.example.com` — traffic flows through the VPS to your home machine.

## Streaming

The Caddyfile sets `flush_interval -1` so ffmpeg's fMP4 output is flushed to the browser immediately — no buffering. Time-to-first-byte depends only on your home machine's connection to RealDebrid (fast, residential IP).

## Resource usage

VPS: ~30MB RAM (Caddy only, no Rails, no ffmpeg)
Home: runs the full stack (Rails + ffmpeg + Postgres)
