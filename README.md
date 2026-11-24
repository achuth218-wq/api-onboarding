# Kong Konnect mTLS setup

This starter bundle configures a self-managed Kong Gateway data plane to connect to a Kong Konnect control plane using mTLS in PKI mode with a CA-signed client certificate.

For API onboarding through GitHub Actions, see [the Orders API onboarding guide](apis/orders/README.md). It includes an OpenAPI specification, separate plugin files, validation, and deployments to Konnect.

## What this setup assumes

- Your Kong Gateway node is a Konnect data plane.
- You want `cluster_mtls = pki`, not a shared pinned certificate.
- You either upload your CA trust anchor in the Konnect UI or generate it there.
- Your data plane presents the full client certificate chain when an intermediate CA is involved.

## Files

- `scripts/generate-ca-and-dp-certs.sh`: generates a root CA, an intermediate CA, and a data plane client certificate chain.
- `scripts/render-kong-conf.sh`: renders `kong/kong.conf` from `.env`.
- `kong/kong.conf.template`: Kong Gateway data plane config for Konnect PKI mode.
- `docker-compose.yml`: optional local container runner for the data plane.

## Quick start

1. Copy `.env.example` to `.env` and fill in the Konnect control plane values.
2. Generate certificates:

```sh
./scripts/generate-ca-and-dp-certs.sh
```

3. In Konnect Gateway Manager, open your control plane and go to `Actions -> Data Plane Certificates`.
4. Upload the CA certificate that Konnect should trust.

If you upload the root CA, keep using `certs/data-plane/tls-chain.crt` on the data plane so the intermediate certificate is sent during the handshake.

5. Render the final Kong config:

```sh
./scripts/render-kong-conf.sh
```

6. Start Kong Gateway:

```sh
docker compose up -d
```

## Generated certificate layout

After running the certificate script, the important files are:

- `certs/root-ca/rootCA.crt`: trust anchor to upload to Konnect.
- `certs/intermediate/intermediate.crt`: intermediate CA certificate.
- `certs/data-plane/tls.key`: data plane private key.
- `certs/data-plane/tls.crt`: data plane leaf certificate.
- `certs/data-plane/tls-chain.crt`: leaf plus intermediate chain. This is the file used by `cluster_cert`.

## Konnect values to copy into `.env`

Use the hostnames from your Konnect control plane:

- `KONNECT_CONTROL_PLANE_ENDPOINT`: example `example.cp.khcp.konghq.com`
- `KONNECT_TELEMETRY_ENDPOINT`: example `example.tp.khcp.konghq.com`

Both values should be hostnames only, without `https://` and without `:443`.

## Notes

- `cluster_control_plane` and `cluster_telemetry_endpoint` must use port `443`.
- `cluster_server_name` and `cluster_telemetry_server_name` should match the Konnect hostnames.
- `lua_ssl_trusted_certificate = system` keeps trust of the Konnect server certificate on the data plane side.
- If your network requires an outbound proxy, add Kong proxy settings separately.
