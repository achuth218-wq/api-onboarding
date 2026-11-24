# Onboard an API into Kong Konnect with GitHub Actions

This example deploys the Orders API's Gateway Service, three Routes, and four plugins into an existing Konnect control plane. Replace the sample contract with your API before deployment. The upstream application and a connected data plane must already exist.

## Files

```text
.github/workflows/konnect-api-onboarding.yml
requirements-apiops.txt
scripts/build-konnect-api.sh
apis/orders/
  openapi.yaml
  gateway-patches.yaml
  plugins/
    key-auth.yaml
    rate-limiting.yaml
    correlation-id.yaml
    request-size-limiting.yaml
```

The OpenAPI file defines `GET /v1/orders`, `POST /v1/orders`, and `GET /v1/orders/{orderId}`. Plugin policies live in separate files and are attached to the generated Service by `deck file add-plugins`.

| Plugin | Example policy |
| --- | --- |
| Key Auth | Require an `apikey` request header; remove it before forwarding upstream |
| Rate Limiting | 100 requests per minute per Consumer, per data-plane node |
| Correlation ID | Forward and echo `X-Correlation-ID`; generate a UUID when absent |
| Request Size Limiting | Maximum request body of 1 MB |

The rate limiter uses `local` counters, which are suitable for this self-managed Konnect hybrid example. For a shared quota across nodes, configure Redis and its credentials. The `cluster` policy is unsupported in Konnect. See [Kong's rate-limiting strategies](https://developer.konghq.com/plugins/rate-limiting/).

## Configure GitHub

Create GitHub environments named `development`, `staging`, and `production` under **Settings → Environments**. Configure these values in each environment:

| Type | Name | Value |
| --- | --- | --- |
| Secret | `KONNECT_TOKEN` | Konnect personal or system-account access token with permission to manage the target control plane's Gateway entities |
| Variable | `KONNECT_CONTROL_PLANE_NAME` | Exact name of the target control plane in the US region, for example `orders-development` |
| Variable | `ORDERS_UPSTREAM_HOST` | Real upstream DNS hostname, without a scheme, port, or path |

The workflow sets `DECK_KONNECT_ADDR` to `https://us.api.konghq.com` for development, staging, and production. You do not need a GitHub `KONNECT_ADDR` variable; any existing value is unused by this workflow. Use a distinct control plane in the US region for each environment. The US management API URL is separate from the `*.cp.khcp.konghq.com` data-plane connection endpoint in the root project's `.env` file.

The upstream is assumed to serve HTTPS on port 443 and handle the full `/v1/orders...` path. Change `gateway-patches.yaml` if your backend uses different settings. Its TLS certificate must be trusted by the data plane. The workflow rejects the example upstream hostname until you provide a real one.

Restrict environment deployments to `main`. Configure required reviewers for `production` if you want GitHub to enforce approval before that job receives credentials. Environment protection is a repository setting and is not created by this workflow file.

The workflow uses `main` as its deployment branch. If your repository uses another default branch, update both trigger branch filters and the deployment job's branch condition.

## Pipeline behavior

1. **Pull request:** validate the OpenAPI document, convert it into Kong configuration, apply Gateway settings, attach plugins, add ownership tags, and validate the generated state offline. No Konnect credentials are used. The configuration template is saved as a workflow artifact.
2. **Push to main:** repeat validation, resolve the template using the `development` environment's control plane and upstream hostname, connect to Konnect, validate against its schemas, print a diff, and synchronize the API. A final diff fails the job if configuration drift remains.
3. **Manual run:** open **Actions → Konnect API onboarding → Run workflow**, select `main`, choose the environment, then choose `plan` or `deploy`. `plan` validates and prints a live diff without changing configuration. `deploy` applies it. Manual runs from other branches only validate; their deployment job is skipped.

The same run's validated template is used by the deployment job. decK is pinned to version `1.70.0`. Deployments to the same environment are serialized and active deployments are not automatically cancelled. Avoid rerunning an old successful workflow to deploy: it uses that run's old commit. Start a new run on `main` to deploy the current configuration.

Diff and sync use `--select-tag api:orders-api --skip-consumers`. Every generated Service, Route, and plugin receives that tag. Keep it stable and exclusive to this API: **removing an entity from these source files deletes the corresponding entity with that ownership tag on the next sync**. Unrelated tagged configurations are outside this workflow's scope. Consumers and their credentials are managed separately.

This example assumes a new API. For an existing Service, first reconcile its names, IDs, and ownership tags with the generated configuration before allowing this workflow to manage it. For additional APIs, give each a distinct stable `x-kong-name`, UUID base, ownership tag, artifact name, file paths, and concurrency group.

## Validate locally

Install [decK](https://developer.konghq.com/deck/) version `1.70.0`, then run from the repository root:

```sh
python3 -m venv .venv-apiops
. .venv-apiops/bin/activate
python -m pip install -r requirements-apiops.txt
bash scripts/build-konnect-api.sh
```

Inspect `build/orders-api.yaml` to see the rendered Service, Routes, and plugins. It is an inspection copy; decK's render command removes IDs. The pipeline deploys `build/orders-api.template.yaml` directly to preserve stable IDs and resolve the control-plane and upstream placeholders at runtime. Local validation uses `offline-validation` as a dummy control-plane name and makes no Gateway API calls. Neither file contains a Konnect token or API consumer credential. `build/` and the virtual environment are ignored by Git.

Offline validation checks the OpenAPI specification and Kong state structure. Plugin configuration is validated against the target control plane during the deployment job. A successful configuration sync does not prove that the data plane can reach the backend; test a real request after deployment.

## Provision access and test

In the same Konnect control plane, create a Consumer and add a Key Auth credential. Store the generated API key securely. This workflow enables Key Auth but does not generate, publish, or rotate client keys. Any Consumer key recognized in the control plane can authenticate to this example API; add an authorization policy such as ACL if access must be restricted to a specific Consumer group.

Set `GATEWAY_URL` to your data plane's HTTPS proxy URL and `API_KEY` to the Consumer's key, then run:

```sh
curl --fail-with-body "${GATEWAY_URL}/v1/orders" \
  --header "apikey: ${API_KEY}"

curl --fail-with-body "${GATEWAY_URL}/v1/orders" \
  --header "apikey: ${API_KEY}" \
  --header 'Content-Type: application/json' \
  --data '{"productId":"product-123","quantity":2}'
```

Requests without an API key should return `401`. An authenticated request with a body exceeding the limit should return `413`; exceeding the per-node quota should return `429`. Use a real Orders backend to verify the success responses. The sample contract does not implement an upstream application or enforce JSON request schemas at runtime; application validation remains the backend's responsibility.

## Rollback and scope

Revert the relevant API or plugin change in Git and merge it to `main` to restore development. Run `deploy` for staging or production after reviewing the rollback diff. Review changes to ownership tags and entity IDs carefully because they can change which resources are managed.

This pipeline manages Gateway configuration in an existing Konnect control plane. Creating control planes, deploying data planes, and publishing API documentation into Konnect Dev Portal are separate operations.

## References

- [OpenAPI-to-Kong conversion](https://developer.konghq.com/deck/file/openapi2kong/)
- [Attaching plugins from separate files](https://developer.konghq.com/deck/file/manipulation/plugins/)
- [decK connection settings](https://developer.konghq.com/deck/configuration/)
- [Runtime environment placeholders](https://developer.konghq.com/deck/reference/env-variables/)
- [Tag-scoped synchronization](https://developer.konghq.com/deck/gateway/sync/)
