DO NOT SHIP

# relay: notes for Friday

I planned for 400 req/s: the README says 400, HANDOFF says 150, and I took the higher one. The blocks are copied from my terminal, with the shell prompt shortened to `$`. Where I write "from reading", I did not run it.

Final run, 400 req/s for 5 minutes, after my changes. This is my final `total:` line:

```
total: sent=119987 status[201:113550 409:3165 500:2867] errors[ECONNRESET:404 TIMEOUT:1] p50=11ms p95=28ms p99=1145ms
```

## REASONS:

### 1. About half of client retries fail at the planned peak

In the line above, 3,165 replays got 409 and 2,867 got 500. That is 2,867 of 6,032, or 47.5%. HANDOFF says a 409 on replay is "expected and correct". The app logs the cause:

```
$ kubectl -n relay logs deploy/relay | grep "failed to store event" | head -3
failed to store event: duplicate key value violates unique constraint "events_idempotency_key"
failed to store event: duplicate key value violates unique constraint "events_idempotency_key"
failed to store event: duplicate key value violates unique constraint "events_idempotency_key"
```

Duplicates are tracked in an in-memory map inside each pod. A retry that reaches another pod, or arrives after a restart, is not recognised. I isolated it with 2 pods at 150 req/s for 60 seconds:

```
total: sent=8997 status[201:8537 409:283 500:177] errors[-] p50=11ms p95=19ms p99=26ms
$ kubectl -n relay logs -l app=relay --prefix --tail=-1 | grep -c "duplicate key"
177
$ kubectl -n relay get pods
NAME                        READY   STATUS    RESTARTS   AGE
postgres-5856b48b88-585s9   1/1     Running   0          5h37m
relay-78566ff4f5-pffmp      1/1     Running   0          9m28s
relay-78566ff4f5-xr6mb      1/1     Running   0          2m52s
```

No restarts and no timeouts, and 177 of 460 replays still failed.

### 2. Pods leak memory and crash under load

Final run, memory per pod every 5 seconds. Two pods reach about 200Mi and come back almost empty, which is a restart:

```
--- 22:48:52
relay-7bb7f5d654-kgj4f      224m   199Mi
relay-7bb7f5d654-mmxv8      181m   203Mi
--- 22:49:07
relay-7bb7f5d654-kgj4f      64m    17Mi
relay-7bb7f5d654-mmxv8      262m   203Mi
--- 22:49:22
relay-7bb7f5d654-kgj4f      196m   40Mi
relay-7bb7f5d654-mmxv8      78m    31Mi
relay-7bb7f5d654-thcbb      173m   39Mi
```

How the container died:

```
$ kubectl -n relay describe pods -l app=relay | grep -A4 "Last State"
    Last State:     Terminated
      Reason:       Error
      Exit Code:    134
      Started:      Fri, 13 Nov 2026 22:49:10 +0100
      Finished:     Fri, 13 Nov 2026 22:51:06 +0100
$ kubectl -n relay logs -l app=relay --previous --tail=20 --prefix | grep -iE "fatal|heap|error"
[pod/relay-7bb7f5d654-mmxv8/relay] FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory
```

All 404 resets in the run are in these six windows:

```
[  65s] sent=1990 status[201:1844 409:58 500:37] errors[ECONNRESET:69] p50=11ms p95=74ms p99=255ms
[  80s] sent=1996 status[201:1823 409:63 500:26] errors[ECONNRESET:84] p50=12ms p95=109ms p99=321ms
[ 200s] sent=2009 status[201:1855 409:18 500:61] errors[ECONNRESET:74] p50=11ms p95=48ms p99=329ms
[ 205s] sent=2005 status[201:1220 409:41 500:27] errors[TIMEOUT:1 ECONNRESET:47] p50=1625ms p95=2028ms p99=2722ms
[ 225s] sent=1995 status[201:1827 409:42 500:57] errors[ECONNRESET:69] p50=12ms p95=324ms p99=643ms
[ 245s] sent=1997 status[201:1879 409:28 500:71] errors[ECONNRESET:61] p50=11ms p95=85ms p99=225ms
```

About five hours after the load stopped, with no traffic:

```
--- 03:46:57
relay-7bb7f5d654-kgj4f      1m    90Mi
relay-7bb7f5d654-mmxv8      1m    105Mi
relay-7bb7f5d654-thcbb      1m    86Mi
```

A fresh pod uses about 17Mi. The same map keeps every payload and never removes one, so the memory is never given back.

### 3. The Terraform has never been applied, and it would not work (from reading)

HANDOFF: "It has never been applied." Friday would be its first run.

```
# terraform/security.tf, node security group
    description     = "App traffic from the load balancer"
    from_port       = 8080
    to_port         = 8080

# terraform/alb.tf, target group
  port     = var.app_node_port

# terraform/variables.tf, app_node_port
  default     = 30080
```

The nodes accept the ALB on 8080 only, and the ALB sends traffic and health checks to 30080. Every health check and every request would be blocked.

```
# terraform/app.tf, bastion
  ami                         = "ami-0c55b159cbfafe1f0"
```

AMI IDs belong to one region and I believe this one is not from eu-west-1, so `apply` would fail partway. I could not verify that without an AWS account.

```
$ terraform validate
Success! The configuration is valid.
```

`validate` checks syntax, so it catches neither.

### 4. Credentials are exposed

`app/.env` was committed with a staging database password and a signing secret. It also went into the image:

```
# app/Dockerfile, as received
COPY . .
RUN rm -f .env
```

```
 => [internal] load .dockerignore                                                                              0.1s
 => => transferring context: 2B                                                                                0.0s
```

The `rm` hides the file in a later layer and leaves it in the earlier one, and the build output shows there was no `.dockerignore` to keep it out. I did not unpack the image to prove the layer; that part is from reading. I stopped both leaks, but the values are in git history and must be rotated.

### 5. Production pieces do not exist yet (from reading)

The Terraform has no IAM role for CI to assume. It creates a Secrets Manager entry for the database URL, but nothing puts it into the cluster as `relay-secrets`. HANDOFF: "No dashboards or alerts yet."

## The same service before my changes

150 req/s for 5 minutes, with only the fixes needed to start it. I ran it twice and it failed the same way both times. Second run:

```
[  30s] sent=754 status[201:699 409:50] errors[-] p50=12ms p95=28ms p99=66ms
[  35s] sent=748 status[201:196 409:6] errors[-] p50=14ms p95=1577ms p99=2005ms
[  40s] sent=749 status[201:25 409:3] errors[TIMEOUT:244] p50=4325ms p95=5766ms p99=5820ms
...
[  70s] sent=748 status[201:20 409:3] errors[TIMEOUT:245] p50=23958ms p95=24910ms p99=25138ms
[  75s] sent=753 status[201:478 409:1 500:16] errors[ECONNRESET:3961 TIMEOUT:218] p50=8ms p95=26ms p99=2335ms
[  80s] sent=748 status[201:712 409:6 500:31] errors[-] p50=10ms p95=19ms p99=24ms

total: sent=44996 status[201:31589 409:1509 500:106] errors[TIMEOUT:3860 ECONNRESET:7932] p50=12ms p95=19ms p99=2239ms
```

Memory and CPU of the single pod, first run:

```
17:27:31  relay-78566ff4f5-qz88m      1m    50Mi
17:28:37  relay-78566ff4f5-qz88m      206m   158Mi
17:29:53  relay-78566ff4f5-qz88m      328m   243Mi
17:30:08  relay-78566ff4f5-qz88m      1181m   243Mi
17:30:23
17:30:39  relay-78566ff4f5-qz88m      312m   56Mi
```

What killed it:

```
$ kubectl -n relay describe pod -l app=relay | grep -A6 "Last State"
    Last State:     Terminated
      Reason:       Error
      Exit Code:    137
$ kubectl -n relay get events --sort-by=.lastTimestamp | grep -iE "unhealthy|killing|oom|backoff|started"
21m         Warning   Unhealthy                 pod/relay-78566ff4f5-qz88m      Liveness probe failed: Get "http://10.244.1.4:8080/health": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
21m         Normal    Killing                   pod/relay-78566ff4f5-qz88m      Container relay failed liveness probe, will be restarted
```

The pod filled its 256Mi limit, stopped answering, and the liveness probe killed it. Each kill cost about 40 seconds of timeouts. 11,898 of 44,996 requests failed (26%). The final run is 2.7 times the load with 3,272 of 119,987 failed (2.7%) and 1 timeout. The 500s went up because the autoscaler now works and ran 3 pods, which exposes reason 1.

## What I changed, in the order I would defend it

My rule: I changed how the service is built, configured, deployed and run. I did not change how it handles requests.

### 1. Made it start (1bde71e, 19ae454, 82bfbd7, 1a97ce9, 97ade9b)

`make up` failed five times, one after another.

**Build.** The Dockerfile copied only `package.json`. I copied the lockfile. I did not switch to `npm install`, because that gives up reproducible builds.

```
 > [4/6] RUN npm ci --omit=dev:
0.473 npm error code EUSAGE
0.473 npm error The `npm ci` command can only install with an existing package-lock.json or
0.473 npm error npm-shrinkwrap.json with lockfileVersion >= 1. Run an install with npm@5 or
0.473 npm error later to generate a package-lock.json file, then try again.
make: *** [build] Error 1
```

**Image pull.** `:latest` defaults the pull policy to `Always`, so the image I loaded into kind was ignored. Set to `IfNotPresent`.

```
$ kubectl -n relay get pod -l app=relay -o jsonpath='{.items[0].spec.containers[0].imagePullPolicy}{"\n"}'
Always
  Warning  Failed     16s               kubelet            Failed to pull image "relay:latest": failed to pull and unpack image "docker.io/library/relay:latest": failed to resolve reference "docker.io/library/relay:latest": pull access denied, repository does not exist or may require authorization: server message: insufficient_scope: authorization failed
  Warning  Failed     16s               kubelet            Error: ErrImagePull
```

**Secret key.** The key in the Secret is `DATABASE_URL`. I changed the deployment to match.

```
relay-64688575d5-tvv9d      0/1     CreateContainerConfigError   0          8s
  Warning  Failed     3m7s (x26 over 8m27s)  kubelet            Error: couldn't find key database-url in Secret relay/relay-secrets
```

**Port.** The app was healthy on 8080 and the probe checked 3000. HANDOFF requires 8080, so everything uses 8080 now, through a named port.

```
relay listening on :8080 (pool max 25)
  Liveness:  http-get http://:3000/health delay=5s timeout=1s period=5s #success=1 #failure=2
  Warning  Unhealthy  5m10s (x16 over 14m)  kubelet            Liveness probe failed: Get "http://10.244.1.3:3000/health": dial tcp 10.244.1.3:3000: connect: connection refused
relay-5749ccf4cf-nhx78      1/1     Running   5 (0s ago)   3m30s
relay-5749ccf4cf-nhx78      0/1     CrashLoopBackOff   5 (1s ago)   4m11s
```

**Logs.** I sent three requests and `kubectl logs` showed only the startup lines, because `LOG_FILE` wrote access logs to a file inside the container. I removed it. After:

```
{"ts":"2026-11-13T15:08:05.113Z","method":"POST","path":"/events","status":201,"ms":17,"key":"test-2"}
{"ts":"2026-11-13T15:08:09.850Z","method":"GET","path":"/health","status":200,"ms":1,"key":null}
{"ts":"2026-11-13T15:08:11.345Z","method":"POST","path":"/events","status":409,"ms":1,"key":"test-2"}
```

Result: health, a new event, and the same key again.

```
{"status":"ok"}{"id":"307130bb-b5cc-4e16-9e17-cfd2f79912cf","signature":"e8caec860f5dd16dc2d0b3e16aa052fa7b15cc0af8a2b9e4a7d463e60943acd5"}{"id":"307130bb-b5cc-4e16-9e17-cfd2f79912cf","duplicate":true}
```

### 2. Stopped CI from damaging production (002f47a, from reading)

```
# .github/workflows/deploy.yml, as received
          kubectl apply -f k8s/
          kubectl -n relay rollout restart deployment/relay
```

That applies the whole folder, including `secret.yaml` (local credentials) and `postgres.yaml` (a database on `emptyDir`). In production relay would then write to a database that is wiped on restart. CI now applies a named list of manifests, tags images by commit SHA, uses OIDC instead of static keys, pins actions, and fails when the rollout fails. I could not run it: no AWS account.

### 3. Kept secrets out of the image and repo (58fd0b6, 500fe99)

A `.dockerignore` keeps `.env` out of the build. `app/.env` is no longer tracked, and `.env.example` has placeholders. See reason 4.

### 4. Sized the pool to the database (90c1cd3)

HANDOFF: `max_connections` is 100 and will not be raised. The config allowed 25 per pod x 10 pods = 250. Now 8 x 10 = 80.

```
$ kubectl -n relay logs -l app=relay --prefix --tail=-1 | grep "pool max"
[pod/relay-7f5d9fcc44-9mlpv/relay] relay listening on :8080 (pool max 8)
[pod/relay-7f5d9fcc44-qtwzq/relay] relay listening on :8080 (pool max 8)
```

The final run peaked at 3 pods, so at most 24 connections. I did not count connections inside the database.

### 5. Made the container stop on SIGTERM (bfcbee3)

Before. `sh` is PID 1 and does not pass the signal on, so the delete waits out the 30 second grace period and ends in a forced kill:

```
$ kubectl -n relay exec deploy/relay -- ps -ef
UID          PID    PPID  C STIME TTY          TIME CMD
root           1       0  0 18:55 ?        00:00:00 sh ./entrypoint.sh
root          34       1  0 18:55 ?        00:00:00 npm start
root          45      34  0 18:55 ?        00:00:00 sh -c node src/server.js
root          46      45  0 18:55 ?        00:00:17 node src/server.js
$ time kubectl -n relay delete pod -l app=relay
kubectl -n relay delete pod -l app=relay  0.05s user 0.02s system 0% cpu 30.438 total
```

After, with tini as PID 1 and `exec node`:

```
$ kubectl -n relay exec deploy/relay -- ps -ef
UID          PID    PPID  C STIME TTY          TIME CMD
root           1       0  0 20:53 ?        00:00:00 /usr/bin/tini -- sh ./entrypoint.sh
root          11       1  1 20:53 ?        00:00:00 node src/server.js
$ time kubectl -n relay delete pod -l app=relay
kubectl -n relay delete pod -l app=relay  0.06s user 0.02s system 11% cpu 0.702 total
```

This 30 second wait was most of the 40 seconds of timeouts per kill in the run before my changes.

### 6. Made autoscaling work and the heap fit (6859bbb)

Autoscaling before. It had never worked, and stayed at 1 replica while CPU reached 1181m:

```
$ kubectl -n relay get hpa
NAME    REFERENCE          TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
relay   Deployment/relay   cpu: <unknown>/70%   1         10        1          4h18m
$ kubectl -n relay describe hpa relay
  ScalingActive  False   FailedGetResourceMetric  the HPA was unable to compute the replica count: failed to get cpu utilization: missing request for cpu in container relay of Pod relay-78566ff4f5-qz88m
  Warning  FailedGetResourceMetric  2m48s (x459 over 126m)  horizontal-pod-autoscaler  failed to get cpu utilization: missing request for cpu in container relay of Pod relay-78566ff4f5-qz88m
```

After a 250m CPU request, and then in the final run:

```
relay   Deployment/relay   cpu: 1%/70%   1         10        1          8h
  ScalingActive   True    ValidMetricFound    the HPA was able to successfully calculate a replica count from cpu resource utilization (percentage of request)

relay   Deployment/relay   cpu: 115%/70%   1         10        1          8h
relay   Deployment/relay   cpu: 49%/70%    1         10        2          8h
relay   Deployment/relay   cpu: 81%/70%    1         10        2          8h
relay   Deployment/relay   cpu: 25%/70%    1         10        3          8h
```

Heap. The Dockerfile set a 512MB heap in a 256Mi container, so Node planned for memory it did not have and hung instead of failing. I set it to 192MB, next to the memory limit in the deployment. Before, then after:

```
$ kubectl -n relay exec deploy/relay -- node -p "Math.round(require('v8').getHeapStatistics().heap_size_limit/1048576)"
515
195
```

The pod now aborts with exit 134 and a clear message (reason 2), and clients see one window of resets instead of 40 seconds of timeouts.

## What I found and left

- **Idempotency in the database.** The fix for reasons 1 and 2, with evidence and a diff, is in `docs/proposed-fixes/01-idempotency-in-database.md`. I left it because it changes how the API answers clients, which is the owners' decision. I also left `DEDUPE_MAX_ENTRIES` unset: it would bound memory but keep the 500s and hide the leak.
- **Graceful drain.** Node exits on SIGTERM without finishing open requests. I deleted one of two pods 20 seconds into a 150 req/s run and saw no connection errors, only a slower window. The 500s here are reason 1. So this is a recommendation, not a proven fault.

  ```
  [  20s] sent=755 status[201:724 409:18 500:5] errors[-] p50=12ms p95=18ms p99=24ms
  [  25s] sent=744 status[201:715 409:22 500:15] errors[-] p50=12ms p95=76ms p99=228ms
  [  30s] sent=756 status[201:705 409:19 500:24] errors[-] p50=11ms p95=18ms p99=23ms
  ```

- **Probes.** There is no readiness probe. During the port failure the pod reported ready while it was being restarted:

  ```
  relay-5749ccf4cf-nhx78      1/1     Running   3 (0s ago)   2m5s
  ```

  Liveness calls `/health`, which queries the database, with `timeout=1s` and 2 failures allowed, so a database blip would restart every pod.
- **Replicas.** After I scaled to 2 by hand, `kubectl apply -f k8s/deployment.yaml` took it back to 1, because the file says `replicas: 1`. Every deploy would do that to the HPA. `minReplicas` is 1 and there is no PodDisruptionBudget.
- **Migrations** run in every pod at startup with no lock (from reading `entrypoint.sh` and `migrate.js`). They also need the database to be up first. On a fresh `make up`, relay restarted 3 times until Postgres was ready, then ran normally:

  ```
  relay-584c868bcb-l5xs5      0/1     CrashLoopBackOff   2 (18s ago)   34s
  relay-584c868bcb-l5xs5      1/1     Running            3 (62s ago)   78s
  $ kubectl -n relay logs deploy/relay --previous
  migrate: failed: connect ECONNREFUSED 10.96.166.115:5432
  ```

  In production the managed database is already running, so this mostly affects local setups. Running migrations once as a Job, before the app starts, would fix both problems.
- **Image.** Every process runs as `root` (see the `ps` output in change 5), on the full `node:22` base. CI has no tests or image scan.
- **Terraform, beyond reason 3** (from reading):
  - `eks.tf`: node group in one subnet and AZ (`public_a`); EKS endpoint open to 0.0.0.0/0; node role has `s3:*` and `secretsmanager:*` on `*` with `http_tokens = "optional"`, so any pod can use it; `encrypted = false` on node disks.
  - `security.tf`: SSH open to 0.0.0.0/0 on nodes and bastion.
  - `variables.tf`: `db_password` has a production-looking default, which also lands in state.
  - `alb.tf`: HTTP only.
  - `main.tf`: no remote state and no provider version. `init` printed `Installing hashicorp/aws v6.73.0...`, the latest.

## What I need before this can ship

- **Service owners:** merge the idempotency fix. Pass criteria: 2 pods at 150 req/s for 60s with zero 500s (today 177), and 400 req/s for 5 minutes with flat memory and no restarts.
- **Infrastructure:** fix the security group port and the AMI, then apply the Terraform to a non-production account before launch day. Create the CI deploy role and a way to deliver `relay-secrets`.
- **Data team:** rotate the staging database password, and confirm relay may use up to 80 of the 100 connections.
- **Security or service owners:** rotate the signing secret.
- **Product:** confirm the peak, 150 or 400.

With the first two done and verified, and the credentials rotated, I would move to SHIP WITH CONDITIONS.

## Questions

1. Is the peak 400 req/s (README) or 150 (HANDOFF)?
2. A replay with the same key and a different payload returns 409 with the original id (from reading). Is that intended?
3. Keys `test-1` and `test-2` with the same body both returned signature `e8caec86...`, because only the payload is signed. Is that intended?
4. Must the S3 archive succeed before the client gets 201? From reading, an S3 failure returns 500 for an event that was saved.
5. The app accepts 64KB bodies and HANDOFF says 8KB. Which is the contract?
6. Who owns relay now, and who reviews changes to request handling?
7. Is TLS terminated somewhere in front of the ALB?