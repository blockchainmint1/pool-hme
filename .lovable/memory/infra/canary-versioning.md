---
name: Canary versioning rule
description: Every change to infra/pool-doctor/mining-canary.sh must bump CANARY_VERSION and add a VERSION LOG entry; the printed banner is how we tell whether the site was republished
type: preference
---

`infra/pool-doctor/mining-canary.sh` starts with a `VERSION LOG` comment block
(newest entry first) and a `CANARY_VERSION="vN"` variable printed in the banner.

**On every change to the canary:**
1. Bump `CANARY_VERSION`.
2. Add a one-paragraph VERSION LOG entry at the top: date + what changed and why.
3. `cp infra/pool-doctor/mining-canary.sh public/install/mining-canary.sh`.
4. Tell the user to **Publish** — `public/install/*` is served from the published
   build, so an un-published change means the box keeps downloading the old script
   even with a cache-buster `?v=$(date +%s)`.

**Why:** on 13 Aug 2026 the user ran the "updated" canary and got `mining-canary v1`
with the old thresholds, because the change had not been published. The version in
the banner is the only reliable proof of which script actually ran.

Apply the same bump-and-log discipline to the other `infra/pool-doctor/*.sh`
diagnostics where a version string already exists (`zcu-shadow`, `zcu-gate`).
