# cn-media

Media stack on kaiser.lan. Currently hosts **Jellyfin**; designed so other media services (immich, audiobookshelf, navidrome) can land here later without redesign.

- **LAN URL**: `https://jellyfin.lan` (step-ca cert)
- **Tailnet URL**: `https://jellyfin.lab.gn.al` (Let's Encrypt wildcard via VPS traefik-lab)
- **On kaiser**: `/home/gonzalo/cn-media/`
- **Operated via systemd**: `sudo systemctl restart docker-compose@cn-media.service` (not direct `docker compose`)

## Architecture (one stack, six services)

| Service | Role |
|---|---|
| `mount-precheck` | Bails before anything else if `/home/gonzalo/docker/data/nfs` isn't mounted. |
| `ts-jellyfin` | Tailscale sidecar; owns the netns. Hostname `jellyfin` (MagicDNS → `jellyfin.ts.gn.al`). `tag:svc`. |
| `jellyfin` | `lscr.io/linuxserver/jellyfin:10.10.7` — pinned. `network_mode: service:ts-jellyfin`. `/config` on local SSD, `/data` (raidnas NFSv3) read-only. `/dev/dri/{card0,renderD128}` mounted for Intel QSV / VAAPI transcoding. |
| `consul-register` | Self-registers `jellyfin` with VPS Consul every 60 s so traefik-lab picks up the route. |
| `promtail` | Ships container logs to VPS Loki at `${INFRA_VPS_TAILNET_IP}:3100`. |
| `node-exporter` | Stack metrics for VPS Prometheus. |
| `ts-jellyfin-watchdog` | Force-recreates dependents when ts-jellyfin restarts (netns drift fix). |
| `watchtower` | Daily image update at 04:00 with `--cleanup`. |

## First-time setup

1. **Mint a Tailscale preauth key** (24 h, `tag:svc`):
   ```sh
   ssh hs.gn.al 'docker exec cloudnet-headscale-1 \
     headscale preauthkeys create -u 2 --tags tag:svc --expiration 24h'
   ```
   (User ID `2` is `gonzaloab@gmail.com` — confirm with `headscale users list`.)

2. **Clone + .env**:
   ```sh
   ssh kaiser.lan 'cd ~ && git clone https://github.com/GonzaloAlvarez/cn-media.git'
   ssh kaiser.lan 'cd ~/cn-media && cp .env.example .env'
   # edit ~/cn-media/.env: fill MEDIA_AUTHKEY, USER_ID, GROUP_ID, TIMEZONE
   ```

3. **Run setup**:
   ```sh
   ssh kaiser.lan 'cd ~/cn-media && ./setup.sh'
   ```
   Idempotent. Fetches step-ca root CA, rsyncs the legacy 1.6 GB jellyfin config from `~/docker/docker-compose-nas/jellyfin/`, clears the legacy `<BaseUrl>/jellyfin</BaseUrl>` from `network.xml` (subdomain routing means root-of-host), installs the systemd unit, starts the service.

4. **Wire ingress** (separate repos):
   - **LAN** (`jellyfin.lan` → kaiser): add the router/service to `cn-home/traefik-lan/dynamic.yml.tmpl`, add the Dashy tile to `cn-home/dashy/conf.yml`, run `cn-home/deploy`. **`--force-recreate` traefik-lan AND dashy** (bind-mount inode quirk).
   - **Tailnet** (`jellyfin.lab.gn.al`): automatic — `consul-register` PUTs the service every 60 s; VPS `traefik-lab` picks it up.
   - **pfSense Host Override**: one-time manual entry `jellyfin.lan → 10.1.1.140` (Services → DNS Resolver → Host Overrides).
   - **VPS Glance bookmark + monitor**: edit `cn-root-docker/tailnet/glance/glance.yml`, restart glance.

## Operations

| Action | Command |
|---|---|
| Restart the stack | `sudo systemctl restart docker-compose@cn-media.service` |
| Tail jellyfin logs | `docker logs -f cn-media-jellyfin-1` |
| Force-recreate after config change | `docker compose -p cn-media up -d --force-recreate --no-deps <svc>` |
| Update jellyfin image | edit `image:` in `docker-compose.yml`, commit, push, on kaiser `git pull && sudo systemctl restart docker-compose@cn-media.service` |
| Check tailnet IP | `docker exec cn-media-ts-jellyfin-1 tailscale ip --4` |
| Enable HW transcoding | Dashboard → Playback → Transcoding → "Hardware acceleration: Intel QuickSync (QSV)" → save → restart |

## Why /data is read-only

The sonarr/radarr/etc. stack in `cn-bittorrent` already writes new media files through its own mount of the same NFS share. Jellyfin only ever **reads**. Mounting `/data:ro` is a cheap guardrail against an accidental UI action that would mutate library files.

## Future media services in this same project

Add a new service block with `network_mode: service:ts-jellyfin` (shares the same tailnet identity), publish its UI port via `ts-jellyfin`'s `ports:`, extend `consul-register` to register it, add the matching router/service to `cn-home/traefik-lan`. The sidecar hostname stays `jellyfin` — or rename later (requires retiring/rotating the auth key).
