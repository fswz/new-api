# Leya Native Deployment

This deployment runs the source-built New API binary under systemd. Caddy
terminates HTTPS, PostgreSQL stores application data, and Redis provides the
shared cache and rate-limit state. Docker is not used.

## Runtime layout

- Application releases: `/srv/leyao-new-api/releases`
- Active release: `/srv/leyao-new-api/current`
- Runtime state: `/var/lib/leyao-new-api`
- Application logs: `/var/log/leyao-new-api`
- Protected environment: `/etc/leyao-new-api/new-api.env`
- AliDNS renewal environment: `/etc/leyao-new-api/alidns-certbot.env`
- Caddy certificate copies: `/etc/caddy/certs/leyao.{fullchain,privkey}.pem`
- systemd unit: `leyao-new-api.service`
- Public origin: `https://leyao.fswz.cc`

The host also runs an existing Palworld service. Its UDP `8211` and `27015`
firewall allowances must remain in place during New API deployments.

The bootstrap script requires an exact 40-character Git commit in
`RELEASE_REF`. It preserves an existing application environment and creates a
new immutable release directory for each deployment. If the Caddy certificate
copies exist, it also preserves the explicit DNS-01 certificate configuration.

`install-dns-certificate.sh` obtains a Let's Encrypt certificate through
AliDNS DNS-01 validation and enables `certbot.timer`. The AliDNS credential file
must remain root-only (`0600`) so unattended renewals can update the certificate
without exposing the key to the application user.

UFW allows only SSH and web traffic over TCP, plus UDP `8211` and `27015` for
the existing Palworld service. The New API process listens on port `3000`, but
that port must not be opened publicly; Caddy is its only public entry point.

## Rollback

Point `/srv/leyao-new-api/current` at a previously verified release directory,
then restart the service:

```bash
sudo ln -sfn /srv/leyao-new-api/releases/<release-id> /srv/leyao-new-api/current
sudo systemctl restart leyao-new-api
curl --fail http://127.0.0.1:3000/api/status
```

Database migrations may not be backward-compatible. Back up PostgreSQL before
deploying application changes that include schema migrations.
