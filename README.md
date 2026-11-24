# Kong Konnect API onboarding — US region

This bundle onboards an API into an existing Konnect control plane connected to your running local Docker data plane.

1. Copy the contents of this folder into your GitHub repository root, including the hidden `.github` folder.
2. Replace `apis/orders/openapi.yaml` with your API contract and adjust the separate plugin files.
3. Create the GitHub `development` environment and set `KONNECT_TOKEN` (secret), `KONNECT_CONTROL_PLANE_NAME` (variable), and `ORDERS_UPSTREAM_HOST` (variable).
4. Use the name of the existing US-region control plane connected to your Docker data plane. Check the upstream protocol and port in `apis/orders/gateway-patches.yaml`.
5. Merge to `main` to deploy, or manually run the workflow on `main` with `plan` to preview changes.

Read the [complete onboarding guide](apis/orders/README.md) for configuration, plugin behavior, API-key provisioning, testing, and optional staging/production deployments.

The pipeline uses `https://us.api.konghq.com`. It contains no Docker Compose setup, data-plane configuration, certificate generation, or data-plane deployment steps.
