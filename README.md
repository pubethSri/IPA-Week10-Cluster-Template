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
epimetheus/                 Argo CD deploys this directory, and only this one
  deployment.yaml           replicas, resources.limits.cpu, resources.limits.memory
  configmap.yaml            DB_POOL_SIZE, CACHE_CUSTOMERS, CACHE_ORDERS_MAX
  service.yaml              the ClusterIP in front of your pods
  ingress.yaml              the ipa.local /pack rule

catalog/
  docker-compose.yml        the database, run by hand on the rancher VM

monitoring/
  values.yaml               Prometheus settings, for the helm install

argocd/
  application.yaml          the Argo CD Application; edit two lines, apply once

pandora/                    the load generator; edit ONE line, apply once
  namespace.yaml
  pvc.yaml
  service.yaml
  deployment.yaml           <- your team name goes here

check-normalisation.sh      checks your cluster is set up correctly
```

**Only `epimetheus/` is synced.** The other four directories are things you run
yourself, once, during setup — Argo CD does not look at them.

**There is no `grafana/` here and that is deliberate.** You create Grafana's
compose file yourself, from a block in the lab sheet — the same act as last
week's Rancher compose, on the same VM. One line of what you type is the answer
to the step after it.

`pandora/` is the load generator: the instrument every result this week is
measured with. One line in it is yours — your team name — and the rest is
deliberately fixed, because a harness that was tuned between runs would make two
of your own results incomparable with no way to tell which.

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

## Where things are, once you are set up

| | |
|---|---|
| Your application | `http://ipa.local:8080/pack` |
| Load generator | `http://ipa.local:9900` |
| Prometheus | `http://ipa.local:9090` |
| Grafana | `http://ipa.local:3000` |
| Argo CD | `http://ipa.local:8080/argocd` |

All of these are your own cluster. `ipa.local` is a line in the hosts file on your
own PC, so it points at your rancher VM and nobody else's.

## Useful while you work

```
kubectl get pods -o wide            # what is running, and where
kubectl get endpoints epimetheus    # which pods the Service is sending to
kubectl describe quota              # how much of your budget is spent
kubectl logs -l app=epimetheus      # all pods at once
kubectl top pods                    # actual usage, not what you asked for
```
