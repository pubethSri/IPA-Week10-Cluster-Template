# Epimetheus — your deployment

This is your pair's repository. Argo CD watches it, so **committing here is how
you change the running system**. Nothing you do with `kubectl` directly is
permanent: it will show as **OutOfSync** in Argo CD, and it is not the version
that gets marked.

> Working imperatively first is fine and often faster — `kubectl scale`,
> `kubectl edit` — but the commit is what makes it real. Argo CD showing
> **OutOfSync** is a standing reminder that Git does not yet match what is
> running.

## What is in here

```
k8s/                        Argo CD deploys this directory, and only this one
  deployment.yaml           replicas, resources.limits.cpu, resources.limits.memory
  configmap.yaml            DB_POOL_SIZE, CACHE_CUSTOMERS, CACHE_ORDERS_MAX
  service.yaml              the ClusterIP in front of your pods
  ingress.yaml              the ipa.local /pack rule

catalog/
  docker-compose.yml        the database, run by hand on the rancher VM

argocd/
  application.yaml          the Argo CD Application; edit two lines, apply once

check-normalisation.sh      checks your cluster is set up correctly
```

**Only `k8s/` is synced.** The other two directories are things you run yourself,
once, during setup — Argo CD does not look at them.

## Where to work

Clone this repository **on the rancher VM**. That is where `kubectl` is, where
the database runs, and where the check script expects to be run. It is the same
place you worked from last week.

## The six settings you can change

| Setting | File | What it is |
|---|---|---|
| `replicas` | `deployment.yaml` | How many pods |
| `resources.limits.cpu` | `deployment.yaml` | CPU ceiling per pod |
| `resources.limits.memory` | `deployment.yaml` | Memory ceiling per pod |
| `DB_POOL_SIZE` | `configmap.yaml` | Database connections held open per pod |
| `CACHE_CUSTOMERS` | `configmap.yaml` | Keep the customer table in memory |
| `CACHE_ORDERS_MAX` | `configmap.yaml` | Maximum orders held in memory; `0` disables |

`ATTEMPT_BUDGET_K` and `BOX_CAPACITY_CM3` are also in `configmap.yaml` so that
you can see them. **Do not change them.** They describe the catalog the service
is packing against, so changing one makes Epimetheus return wrong answers rather
than slow ones — and the load generator will refuse to start a run against a
deployment whose budget disagrees with its catalog.

## Two things that catch everybody

**Editing the ConfigMap does not restart anything.** A pod reads its environment
once, at start. After a config change lands:

```
kubectl rollout restart deployment/epimetheus
```

If a setting you changed does not seem to be doing anything, check this first.

**Your namespace has a ResourceQuota, and it bounds *limits*, not requests.**
So pod size and pod count trade against each other. Ask for more than the quota
allows and the extra pod stays `Pending` — which is the quota working:

```
kubectl describe quota
kubectl get pods
```

## Where the database password is

It is not in this repository, and it must not be. `DB_URL` is a Secret, created
for you during setup. Never commit a credential — not even to a private repo.

If your pods crash-loop with database errors and Argo CD says **Synced**, the
Secret is the thing to check: Argo CD does not manage it, so it can be missing
while everything Argo CD knows about is green.

```
kubectl get secret epimetheus-db
```

## Checking your cluster

Run this on the rancher VM after finishing the setup section, and again any time
something behaves strangely:

```
./check-normalisation.sh
```

It reads your cluster and changes nothing. It reports **every** check rather than
stopping at the first problem, so one run tells you everything that needs fixing.
`PASS` and `FAIL` are what they look like; `WARN` is worth reading but does not
block you.

## Useful while you work

```
kubectl get pods -o wide            # what is running, and where
kubectl get endpoints epimetheus    # which pods the Service is sending to
kubectl describe quota              # how much of your budget is spent
kubectl logs -l app=epimetheus      # all pods at once
kubectl top pods                    # actual usage, not what you asked for
```
