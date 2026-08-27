# VPS pull-based deployment

`world-app-vps-deploy.timer` polls `waonme/world-app` main and performs the complete web build on the production VPS.

The source build runs in an unprivileged Kubernetes Job with no service-account token and explicit CPU/memory limits. A separate rootless BuildKit Job creates an OCI archive, which the host imports into MicroK8s containerd. The Deployment is changed only after both Jobs succeed.

Production verification requires all of the following:

- the Deployment rollout completes with an explicit readiness probe;
- `/cc-info` reports the exact Git commit;
- `/` is reachable;
- the JavaScript asset referenced by `/` is reachable.

On rollout or smoke-test failure, the service restores the previous image. Failed commits are retried after a ten-minute backoff; a new main commit is attempted immediately.

The stable installed copy is `/home/orange/world-app-deployer/bin/deploy.sh`. Updating this repository does not replace the running deployer automatically; deployer changes require a deliberate reinstall.
