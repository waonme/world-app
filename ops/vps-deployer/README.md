# VPS pull-based deployment

`world-app-vps-deploy.timer` polls `waonme/world-app` main and performs the complete web build on the production VPS.

The source build runs in an unprivileged Kubernetes Job with no service-account token and explicit CPU/memory limits. A separate rootless BuildKit Job creates an OCI archive, which the host imports into MicroK8s containerd. The Deployment is changed only after both Jobs succeed.

Before building the web bundle, the Job verifies the documented fork anchors and runs focused mute, legacy-data, recovery, reply-destination, and legacy-WebKit placement tests. It also refuses to follow a rewritten/non-fast-forward `main`; an ordinary revert commit remains allowed.

Production verification requires all of the following:

- the Deployment rollout completes with an explicit readiness probe;
- `/cc-info` reports the exact Git commit;
- `/` is reachable;
- the JavaScript asset referenced by `/` is reachable.

Each invocation builds from a fresh detached worktree, verifies its exact HEAD and tracked contents before and after the source build, and uses fresh per-attempt artifacts. A retry first stops any build Job left by an interrupted invocation, so a writable old workspace or archive can never be relabeled as the new target SHA.

Immediately before patching, the deployer saves the complete live Deployment and the prior `deployed-sha` in a persistent `state/inflight` transaction. On any catchable failure or TERM after the patch begins, the EXIT handler restores the saved Deployment object—including strategy, pod-template annotations, probes, pull policy, image, and sidecars—and atomically restores the prior SHA state. The atomic `deployed-sha` update is the success commit point; signals are masked across that short transition. An interrupted transaction is completed or rolled back before the next build.

The systemd unit uses `KillMode=mixed` and gives rollback four minutes with `TimeoutStopSec=4min`, exceeding the Kubernetes rollback timeout. `TimeoutStartSec=60min` covers both build Jobs plus rollout and smoke verification. The smoke check fetches `/` once per attempt and treats `/cc-info`, root-document, asset-discovery, and asset-fetch failures uniformly. Failed commits are retried after a ten-minute backoff; during that window the service exits with temporary-failure status `75` without changing the original failure timestamp. A new main commit is attempted immediately.

If `state/deployed-sha` is missing, the deployer recovers it from a current image tagged as `localhost/world-app:<40-hex-commit>` and still enforces the fast-forward check. An unrecognized current image is refused. For a reviewed first installation only, an operator may run the command once with `WORLD_APP_ALLOW_INITIAL_BOOTSTRAP=1`; do not persist that variable in the systemd unit.

The stable installed files are `/home/orange/world-app-deployer/bin/deploy.sh`, `/home/orange/world-app-deployer/bin/deploy-lib.sh`, and `/etc/systemd/system/world-app-vps-deploy.service`. Updating this repository does not replace the running deployer automatically; deployer changes require a deliberate reinstall and `systemctl daemon-reload`.

The local, network-free regression tests are:

```sh
ops/vps-deployer/test-deploy.sh
scripts/test-prepare-upstream-sync.sh
```

They exercise all Job terminal states, exact-worktree and non-fast-forward rejection, full fake-Kubernetes rollback, TERM-safe state transitions, stale-attempt cleanup, non-extending backoff, one-fetch smoke verification, and mirror provenance with temporary repositories and fake commands. CI and the VPS source-build Job run both tests. The isolated source-build Job downloads an architecture-matched jq 1.8.2 binary and verifies its pinned SHA-256 before use; the test fails instead of skipping transaction coverage when jq is unavailable. CI also runs `bash -n` over every deployer shell file.

## Releasing a deployer change

The deployer must be bootstrapped before the `main` commit that depends on its new gate. Because `deploy.sh` and `deploy-lib.sh` are one versioned unit, update them in this order:

1. Stop `world-app-vps-deploy.timer` and wait for any active `world-app-vps-deploy.service` invocation to finish. Do not replace files while the timer can start the script.
2. From the reviewed integration commit, run `bash -n ops/vps-deployer/deploy.sh ops/vps-deployer/deploy-lib.sh ops/vps-deployer/test-deploy.sh` and `ops/vps-deployer/test-deploy.sh`.
3. Copy `deploy-lib.sh` to a temporary file in `/home/orange/world-app-deployer/bin`, atomically rename it into place, then do the same for `deploy.sh`. Installing the library first ensures the new script never sees an old or missing library.
4. Install `world-app-vps-deploy.service` at `/etc/systemd/system/world-app-vps-deploy.service`, then run `systemctl daemon-reload`. Keep the timer stopped throughout this step so the four-minute rollback timeout is active before the new script can run.
5. Compare SHA-256 values of both installed scripts and the installed service unit with the reviewed source files. If any differs, keep the timer stopped and restore the old matched scripts and unit.
6. Start `world-app-vps-deploy.service` once while `main` still points at the current deployed commit. It must report that the exact SHA is already deployed and leave no unresolved `state/inflight` transaction.
7. Start the timer again. Only then merge the application PR into `main`.
8. Verify the timer result and `/cc-info` against the merged SHA. Keep the old scripts and service unit as a matched rollback set until acceptance completes.

If step 1 cannot be completed first, pause the timer before merging. Do not merge a deployer-gate change and rely on the old installed copy to protect that same release.
