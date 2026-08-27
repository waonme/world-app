# VPS pull-based deployment

`world-app-vps-deploy.timer` polls `waonme/world-app` main and performs the complete web build on the production VPS.

The source build runs in an unprivileged Kubernetes Job with no service-account token and explicit CPU/memory limits. A separate rootless BuildKit Job creates an OCI archive, which the host imports into MicroK8s containerd. The Deployment is changed only after both Jobs succeed.

Before building the web bundle, the Job verifies the documented fork anchors and runs focused mute, legacy-data, recovery, reply-destination, and legacy-WebKit placement tests. It also refuses to follow a rewritten/non-fast-forward `main`; an ordinary revert commit remains allowed.

Production verification requires all of the following:

- the Deployment rollout completes with an explicit readiness probe;
- `/cc-info` reports the exact Git commit;
- `/` is reachable;
- the JavaScript asset referenced by `/` is reachable.

On rollout or smoke-test failure, the service restores the previous image. Failed commits are retried after a ten-minute backoff; a new main commit is attempted immediately.

The stable installed copy is `/home/orange/world-app-deployer/bin/deploy.sh`. Updating this repository does not replace the running deployer automatically; deployer changes require a deliberate reinstall.

## Releasing a deployer change

The deployer must be bootstrapped before the `main` commit that depends on its new gate:

1. From the reviewed integration commit, syntax-check `deploy.sh`, install that exact file atomically as the stable copy, and compare its SHA-256 with the reviewed source.
2. Run the installed copy once while `main` still points at the current deployed commit. It should report that the exact SHA is already deployed.
3. Only then merge the application PR into `main`. The newly installed deployer will run the fork tests from that target worktree before rollout.
4. Verify the timer result and `/cc-info` against the merged SHA. Keep the old installed script as a rollback copy until acceptance completes.

If step 1 cannot be completed first, pause the timer before merging. Do not merge a deployer-gate change and rely on the old installed copy to protect that same release.
