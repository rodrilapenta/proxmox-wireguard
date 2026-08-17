# Proxmox WireGuard

Automated, state-aware WireGuard VPN gateway deployment for Proxmox VE.

It creates and manages a dedicated Debian VM with WireGuard, nftables,
health checks, recovery/wipe logic, hardened administration, and client
provisioning. It is intended for homes, offices, labs, and other networks
running Proxmox VE.

---

## What it builds

The default deployment creates:

- one Proxmox VM named `wireguard-gateway`;
- Debian 13 generic cloud image;
- 1 vCPU;
- 1 GB RAM;
- 8 GB disk;
- static LAN IPv4 selected during setup;
- WireGuard server on UDP `51820`;
- VPN network `10.77.77.0/24`;
- WireGuard server address `10.77.77.1`;
- nftables firewall + NAT;
- IPv4 forwarding;
- QEMU Guest Agent;
- unattended security updates;
- SSH hardening;
- persistent deployment metadata;
- health checks;
- an initial Proxmox snapshot named `wireguard-ready-01`.

The VM name `wireguard-gateway` is intentionally fixed so older deployments can
still be recognized. New deployments are also tagged in Proxmox with:

```text
proxmox-wireguard-managed
```

---

## What it is for

Typical uses include:

- accessing home computers with RDP/SSH from outside;
- reaching Home Assistant or other LAN-only services;
- administering Proxmox without publishing its web UI;
- accessing NAS/SMB services through the VPN;
- using a full tunnel so Internet traffic exits through the home connection;
- keeping one VPN configuration that works from laptops, phones, tablets, or
  any other WireGuard-compatible client.

The project does **not** depend on a specific phone, operating system, router
brand, or client device.

---

## Network model

Example topology:

```text
Internet
   |
Public IPv4 / DDNS
   |
Home router
   |
UDP 51820 port-forward
   |
192.168.x.x  wireguard-gateway VM
   |
WireGuard 10.77.77.0/24
   |
Home LAN
```

Only the WireGuard UDP port should be exposed publicly.

Do **not** expose services such as:

```text
3389/tcp  RDP
445/tcp   SMB
8006/tcp  Proxmox
8123/tcp  Home Assistant
22/tcp    SSH
```

Use WireGuard to reach those services through the private LAN instead.

---

## Requirements

### Proxmox

You need:

- Proxmox VE;
- root access to the Proxmox host;
- an active Linux bridge connected to the LAN, usually `vmbr0`;
- storage capable of holding VM disks;
- Internet access from the Proxmox host to download Debian packages/images;
- `curl`, `python3`, OpenSSH client tools, and the normal Proxmox `qm` utilities.

The installer auto-detects most of this.

### Home network

You need:

- a LAN IPv4 range;
- an unused static IPv4 for the WireGuard VM;
- a router that can forward UDP ports;
- a public IPv4 reachable from the Internet, or an upstream network setup that
  allows inbound forwarding;
- optionally a DDNS hostname if the public IPv4 changes.

If the Internet connection is behind CGNAT and inbound traffic cannot reach the
home router, normal UDP port forwarding will not be enough. In that case the ISP
must provide a reachable public address or another connectivity design is needed.

### DNS

The installer asks which DNS server VPN clients should use.

This may be:

- the router;
- Pi-hole;
- AdGuard Home;
- another LAN resolver;
- a public resolver.

If Proxmox itself uses Tailscale/MagicDNS, the automatically detected resolver may
be `100.100.100.100`. Do not blindly accept it unless that is genuinely the DNS
you want VPN clients to use.

---

## Router configuration

The script intentionally does **not** modify the home router.

After the server is installed and validated, create one port-forward:

```text
Protocol:       UDP
External port:  51820
Internal IP:    <WireGuard VM LAN IP>
Internal port:  51820
```

Example:

```text
UDP 51820 -> 192.168.68.11:51820
```

If there are multiple routers/NAT layers, inbound UDP must ultimately reach the
router that owns the LAN containing the WireGuard VM.

A DDNS hostname is recommended on dynamic public-IP connections.

---

## Installation

The recommended installation method is to clone the repository directly on the
Proxmox host:

```bash
cd /root
git clone https://github.com/rodrilapenta/proxmox-wireguard.git
cd proxmox-wireguard
chmod +x install-proxmox-wireguard.sh
./install-proxmox-wireguard.sh
```

Cloning the repository keeps the project structure intact and makes future
updates straightforward.

### Updating the installer

If the repository is already cloned and you only want the latest installer code:

```bash
cd /root/proxmox-wireguard
git pull
```

Then run the installer again:

```bash
./install-proxmox-wireguard.sh
```

The installer detects the existing deployment state and offers recovery,
healthcheck, or wipe/rebuild actions as appropriate.

> **Important:** Do not run `git pull` while you have local modifications you
> want to keep unless you understand how Git will merge them. Runtime-generated
> deployment configuration is excluded through `.gitignore`.

### Installing a fixed version

For reproducible deployments, you can clone the repository and check out a tagged
release instead of following the moving default branch:

```bash
git clone https://github.com/rodrilapenta/proxmox-wireguard.git
cd proxmox-wireguard
git checkout v1.0.0
chmod +x install-proxmox-wireguard.sh
./install-proxmox-wireguard.sh
```

GitHub Releases may also provide downloadable source archives for users who do not
want to use Git, but `git clone` is the primary installation path.

### Fresh-install flow

The installer:

1. detects bridge, gateway, LAN CIDR, storage, public IPv4 and other host details;
2. proposes a free VMID and VM LAN address;
3. asks for DNS;
4. asks whether to use:
   - detected public IPv4;
   - DNS/DDNS hostname;
   - another IPv4;
5. validates the environment;
6. shows the proposed VM;
7. asks:

```text
Create VM ... with the configuration above? [Y/n]:
```

Pressing Enter accepts the creation.

Then it:

1. downloads the Debian 13 cloud image;
2. verifies its SHA-512 checksum;
3. generates a dedicated deployment SSH key;
4. creates the VM;
5. configures cloud-init;
6. waits for SSH/cloud-init;
7. installs WireGuard and nftables;
8. applies hardening;
9. runs health checks;
10. persists recovery metadata;
11. creates the initial snapshot.

---

## Administrator access

The VM contains an administrative user:

```text
wireguardadmin
```

### Deployment key

The installer generates a dedicated SSH key used for automation/recovery:

```text
/root/.ssh/wireguard-gateway_ed25519
/root/.ssh/wireguard-gateway_ed25519.pub
```

From the Proxmox host:

```bash
ssh -i /root/.ssh/wireguard-gateway_ed25519 \
  wireguardadmin@<VM-IP>
```

### Human administrator key

During bootstrap the installer optionally allows a separate SSH public key to be
added for normal human administration.

The wizard can be run again inside the VM:

```bash
sudo /opt/proxmox-wireguard/guest/45-admin-access.sh
```

### Emergency console password

The setup can optionally assign a local password to `wireguardadmin`.

That password is intended for the Proxmox VM console.

SSH remains key-only; password authentication over SSH stays disabled.

---

## Creating WireGuard clients

Enter the WireGuard VM:

```bash
ssh -i /root/.ssh/wireguard-gateway_ed25519 \
  wireguardadmin@<VM-IP>
```

Create a peer:

```bash
sudo /opt/proxmox-wireguard/peers/wireguard-peer-add.sh <peer-name>
```

Examples of valid names might be:

```text
phone
laptop
work-pc
tablet
travel-router
```

The name has no platform-specific meaning. It is only an identifier.

---

## Split vs Full tunnel

Each peer can have two routing modes.

### Split tunnel

```text
Local/LAN traffic via VPN; Internet direct
```

Only traffic destined for the home LAN and WireGuard VPN network travels through
the tunnel.

Normal Internet traffic continues through the client's current connection.

This is generally the best mode when the goal is simply to reach home services.

### Full tunnel

```text
All traffic, including Internet, via VPN
```

All IPv4 traffic goes through the home WireGuard server.

The client effectively uses the home Internet connection as its exit point.

---

## DDNS vs Direct-IP profiles

When a DDNS endpoint and current public IPv4 are available, each peer generates
four profiles:

```text
<peer>-split-ddns.conf
<peer>-full-ddns.conf
<peer>-split-ip.conf
<peer>-full-ip.conf
```

The peer wizard prints four clearly labelled QR codes:

```text
1/4 Split / DDNS
    Local/LAN traffic via VPN; Internet direct

2/4 Full / DDNS
    All traffic, including Internet, via VPN

3/4 Split / Direct IP
    Local/LAN traffic via VPN; Internet direct

4/4 Full / Direct IP
    All traffic, including Internet, via VPN
```

### DDNS profiles

Use the configured hostname:

```text
Endpoint = vpn.example.net:51820
```

This is normally preferred when the ISP changes the public IPv4.

### Direct-IP profiles

Use the currently detected public IPv4:

```text
Endpoint = 203.0.113.10:51820
```

They are useful as a fallback when a client temporarily has problems resolving
the DDNS hostname.

A direct-IP profile stops working after the public IPv4 changes until the profile
is updated.

---

## Peer export security

The client private key must temporarily exist in the generated export files so
the configuration and QR code can be imported.

After printing the profiles/QR codes, the peer wizard asks:

```text
Have you imported all desired profiles and want to purge the exports now? [y/N]:
```

Choose `y` once the required profiles are safely imported. The temporary export
files containing the client private key are deleted automatically.

If you choose `n` or press Enter, the exports are kept temporarily and can be
removed later with:

```bash
sudo /opt/proxmox-wireguard/peers/wireguard-peer-purge-export.sh <peer-name>
```

Purging exports does **not** revoke the WireGuard peer.

The server keeps the information required to authenticate the peer, while the
client private key no longer remains in the export directory.

To revoke a peer instead:

```bash
sudo /opt/proxmox-wireguard/peers/wireguard-peer-revoke.sh <peer-name>
```

---

## Peer helper commands

List peers:

```bash
sudo /opt/proxmox-wireguard/peers/wireguard-peer-list.sh
```

Show a QR again while the export still exists:

```bash
sudo /opt/proxmox-wireguard/peers/wireguard-peer-qr.sh <peer-name> split-ddns
sudo /opt/proxmox-wireguard/peers/wireguard-peer-qr.sh <peer-name> full-ddns
sudo /opt/proxmox-wireguard/peers/wireguard-peer-qr.sh <peer-name> split-ip
sudo /opt/proxmox-wireguard/peers/wireguard-peer-qr.sh <peer-name> full-ip
```

Print a config:

```bash
sudo /opt/proxmox-wireguard/peers/wireguard-peer-export.sh <peer-name> split-ddns
```

Purge exported private-key material:

```bash
sudo /opt/proxmox-wireguard/peers/wireguard-peer-purge-export.sh <peer-name>
```

Revoke the peer:

```bash
sudo /opt/proxmox-wireguard/peers/wireguard-peer-revoke.sh <peer-name>
```

---

## Checking the server

Inside the WireGuard VM:

```bash
sudo wg show
```

A connected peer should eventually show:

```text
latest handshake: ...
transfer: ... received, ... sent
```

Server healthcheck:

```bash
sudo /opt/proxmox-wireguard/guest/60-healthcheck.sh
```

The healthcheck validates:

- WireGuard service;
- `wg0`;
- listening UDP port;
- IPv4 forwarding;
- nftables;
- LAN gateway;
- configured DNS;
- DNS resolution;
- Internet IPv4 reachability;
- service enablement;
- QEMU Guest Agent.

Successful health state is persisted in:

```text
/var/lib/proxmox-wireguard/healthcheck.ok
```

The most recent report is stored in:

```text
/var/lib/proxmox-wireguard/healthcheck.last
```

---

## Recovery after interrupted installs

The top-level installer is state-aware.

It can detect states including:

```text
fresh
vm-stopped
vm-no-ssh
cloud-init-pending
needs-bootstrap
bootstrap-incomplete
services-incomplete
healthcheck-failing
needs-snapshot
complete
foreign-vm
```

When an incomplete deployment exists:

```text
1) Continue/recover from the detected state
2) Wipe this WireGuard deployment and rebuild from scratch
3) Exit
```

Missing configuration is requested only after `Continue/recover` is selected.

The installer does not ask for values that are about to be destroyed by a wipe.

---

## Persistent recovery metadata

Deleting and replacing the copied installer directory should not destroy the
deployment identity/configuration.

Non-secret recovery configuration is persisted outside the package at:

```text
/var/lib/proxmox-wireguard/deployment.conf
```

on the Proxmox host and also inside the guest at:

```text
/etc/proxmox-wireguard/deployment.conf
```

Recovery can additionally use:

- Proxmox VM metadata;
- QEMU Guest Agent;
- SSH guest metadata.

The host-state file does **not** contain WireGuard private keys or peer PSKs.

---

## Wipe and rebuild

Choosing:

```text
Wipe this WireGuard deployment and rebuild from scratch
```

is intentionally destructive.

The wipe removes project-owned state including:

- the managed VM;
- VM disks;
- snapshots;
- generated cloud-init snippet;
- deployment SSH key pair;
- persistent host recovery metadata;
- generated configuration;
- project-owned Debian cloud-image cache;
- stale SSH `known_hosts` entries for the managed VM IP;
- stale neighbor/ARP state for the managed VM IP.

The installer then restarts as a fresh deployment and asks for configuration
again.

The wipe refuses to destroy a VM that does not appear to belong to this project.

---

## Snapshot

A successful installation creates:

```text
wireguard-ready-01
```

This is intended as a known-good post-install state.

---

## Security model

Key design choices:

- only WireGuard UDP is exposed publicly;
- SSH password login is disabled;
- root SSH login is disabled;
- administration uses SSH keys;
- each WireGuard peer has its own key pair;
- each peer uses a preshared key;
- client private-key exports can be purged after import;
- nftables uses explicit firewall/NAT rules;
- server private keys stay in the guest;
- recovery metadata stored on Proxmox contains configuration, not WireGuard
  secrets.

---

## Common issues

### DDNS does not match public IPv4

The installer compares the DDNS A record with the currently detected public IPv4.

A mismatch may indicate:

- DDNS update delay;
- DNS caching;
- incorrect DDNS configuration.

### Client says endpoint hostname cannot be resolved

Try a generated `*-ip.conf` profile.

If direct IP works, the WireGuard server is reachable and the problem is DNS
resolution on the client/network path.

### `REMOTE HOST IDENTIFICATION HAS CHANGED`

A rebuilt VM has a new SSH server host key.

The installer automatically removes stale `known_hosts` entries for the managed
VM IP during a controlled wipe/rebuild.

### VM IP appears in neighbor cache after wipe

ARP/neighbor entries may outlive a destroyed VM temporarily.

The wipe flushes the managed VM IP and preflight does not treat cache presence
alone as proof of an address conflict.

### Proxmox thin-pool warnings

Proxmox may warn when thin-provisioned virtual sizes exceed the physical thin
pool.

This is independent from WireGuard itself, but the administrator should monitor
real thin-pool usage and configure storage capacity/auto-extension appropriately.

---

## Files and directories

On the Proxmox host:

```text
/root/proxmox-wireguard/
/root/.ssh/wireguard-gateway_ed25519
/var/lib/proxmox-wireguard/deployment.conf
/var/lib/vz/snippets/proxmox-wireguard-<VMID>-user.yaml
```

Inside the VM:

```text
/opt/proxmox-wireguard/
/etc/wireguard/wg0.conf
/etc/proxmox-wireguard/deployment.conf
/var/lib/proxmox-wireguard/
```

---

## License

This project is licensed under the MIT License. See [`LICENSE`](LICENSE) for details.
