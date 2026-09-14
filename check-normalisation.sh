#!/usr/bin/env bash
#
# Check that your cluster is set up correctly for this week.
#
#   ./check-normalisation.sh [your-namespace]
#
# RUN IT ON THE RANCHER VM, from your clone of this repository — that is where
# kubectl and HAProxy both live. With no argument it uses your current kubectl
# namespace.
#
# Run it once you have finished the setup section of the lab sheet, and again any
# time something behaves strangely. It only reads; it changes nothing.
#
# It checks every item and reports all of them, rather than stopping at the first
# problem — you want to know everything that is wrong in one pass, not to find
# the next thing after fixing this one.
#
# Exit status: 0 if nothing FAILed, 1 otherwise. WARN never fails the run.

set -uo pipefail

STUDENT_NS="${1:-${STUDENT_NS:-}}"
PANDORA_NS="${PANDORA_NS:-pandora}"
INFRA_NODE="${INFRA_NODE:-worker2}"
STUDENT_NODE="${STUDENT_NODE:-worker1}"

pass=0
fail=0
warn=0

# Colour, when the terminal will take it. The words PASS/FAIL/WARN carry the
# meaning by themselves — colour only reinforces them — so a pipe, a redirect, a
# dumb terminal or NO_COLOR=1 loses nothing. CLICOLOR_FORCE=1 keeps colour
# through a pipe, for `... | less -R`.
#
# Deliberately not green/red. That is the one pair red-green colour blindness
# cannot separate, and it is by far the most common kind. Blue, amber and
# magenta stay distinct under it, because magenta keeps a blue component that
# amber has none of.
# NO_COLOR always wins. Otherwise colour if it was forced, or if stdout is a
# terminal that can show it. Forcing is what makes `... | less -R` work.
if [ -n "${NO_COLOR:-}" ]; then
    C_PASS='' ; C_WARN='' ; C_FAIL='' ; C_OFF=''
elif [ -n "${CLICOLOR_FORCE:-}" ] || { [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; }; then
    if [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]; then
        C_PASS=$'\033[38;5;32m'     # blue
        C_WARN=$'\033[38;5;214m'    # amber
        C_FAIL=$'\033[1;38;5;170m'  # magenta, bold
    else
        C_PASS=$'\033[34m' ; C_WARN=$'\033[33m' ; C_FAIL=$'\033[1;35m'
    fi
    C_OFF=$'\033[0m'
else
    C_PASS='' ; C_WARN='' ; C_FAIL='' ; C_OFF=''
fi

ok()   { printf '%sPASS%s  %s\n' "$C_PASS" "$C_OFF" "$*"; pass=$((pass + 1)); }
no()   { printf '%sFAIL%s  %s\n' "$C_FAIL" "$C_OFF" "$*"; fail=$((fail + 1)); }
warned() { printf '%sWARN%s  %s\n' "$C_WARN" "$C_OFF" "$*"; warn=$((warn + 1)); }
note() { printf '      %s\n' "$*"; }

hr() { printf -- '---- %s %s\n' "$1" "$(printf '%.0s-' $(seq 1 $((60 - ${#1}))))"; }

# --------------------------------------------------------------------------
# Preconditions
# --------------------------------------------------------------------------

if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl not found. Run this where you run kubectl (the rancher VM)." >&2
    exit 2
fi

if ! kubectl version -o json >/dev/null 2>&1 && ! kubectl get --raw /readyz >/dev/null 2>&1; then
    echo "Cannot reach the cluster. Check your kubeconfig before anything below." >&2
    exit 2
fi

if [ -z "$STUDENT_NS" ]; then
    # Fall back to whatever your context is set to — the namespace you set with
    # `kubectl config set-context --current --namespace=...`.
    STUDENT_NS=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
fi

if [ -z "$STUDENT_NS" ]; then
    echo "usage: $0 <your-namespace>" >&2
    echo "       the namespace your Epimetheus deployment lives in." >&2
    echo "       Omit it to use your current kubectl namespace:" >&2
    echo "         kubectl config set-context --current --namespace=<ns>" >&2
    exit 2
fi

echo
echo "Cluster setup check    namespace: ${STUDENT_NS}"
echo

# --------------------------------------------------------------------------
hr "nodes"
# --------------------------------------------------------------------------
#
# First, because every nodeSelector in this lab names a node by hostname. A node
# named something else makes the taint, the pinning and the placement checks all
# fail in confusing ways, and it is the one problem that explains the rest.

nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

for n in "$STUDENT_NODE" "$INFRA_NODE"; do
    if grep -qx "$n" <<<"$nodes"; then
        ok "node ${n} exists"
    else
        no "node ${n} not found — every nodeSelector in this lab names it"
        note "nodes present: $(tr '\n' ' ' <<<"$nodes")"
    fi
done

# --------------------------------------------------------------------------
hr "1. Week09 teardown"
# --------------------------------------------------------------------------
#
# Last week's application is deleted rather than scaled down. Scaling it down
# does not stick: Argo CD self-heal puts it back, and so does an autoscaler if
# you set one up. Nothing is lost — the manifests are still in your Week09
# repository and Argo CD can redeploy them in a minute.
#
# ingress-nginx and argocd are NOT removed. This week routes and syncs through
# them.

for ns in lab dev prod; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        no "namespace '${ns}' still exists — Week09's application was not torn down"
        note "kubectl delete namespace ${ns}"
    else
        ok "namespace '${ns}' is gone"
    fi
done

for ns in ingress-nginx argocd; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        ok "namespace '${ns}' kept, as it must be"
    else
        no "namespace '${ns}' is MISSING — Week10 needs it and teardown went too far"
    fi
done

# --------------------------------------------------------------------------
hr "2. the taint"
# --------------------------------------------------------------------------
#
# A taint repels; it does not attract. This one stops your workload from landing
# on worker2 — it does not move anything there. Anything that belongs on worker2
# needs a matching toleration AND a nodeSelector, which is why the next check
# exists at all.

taint=$(kubectl get node "$INFRA_NODE" \
    -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}' 2>/dev/null)

if grep -qx 'dedicated=infra:NoSchedule' <<<"$taint"; then
    ok "${INFRA_NODE} carries dedicated=infra:NoSchedule"
else
    no "${INFRA_NODE} is not tainted dedicated=infra:NoSchedule"
    note "kubectl taint node ${INFRA_NODE} dedicated=infra:NoSchedule"
    [ -n "$taint" ] && note "taints found: $(tr '\n' ' ' <<<"$taint")"
fi

# --------------------------------------------------------------------------
hr "3. ingress-nginx pinned to ${INFRA_NODE}, one replica"
# --------------------------------------------------------------------------
#
# The ingress controller handles every request that reaches your application, so
# it does real work under load. It is pinned to worker2 so that work is not
# competing with your own pods for worker1's CPU — otherwise your measurements
# would be partly about someone else's traffic.

ing_replicas=$(kubectl -n ingress-nginx get deploy ingress-nginx-controller \
    -o jsonpath='{.spec.replicas}' 2>/dev/null)

if [ "$ing_replicas" = "1" ]; then
    ok "ingress-nginx replicaCount is 1"
elif [ -z "$ing_replicas" ]; then
    no "ingress-nginx-controller deployment not found in namespace ingress-nginx"
else
    no "ingress-nginx has ${ing_replicas} replicas, expected 1"
    note "pinned to one node, the second replica survives no node loss"
fi

ing_nodes=$(kubectl -n ingress-nginx get pods \
    -l app.kubernetes.io/component=controller \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u | grep -v '^$')

if [ -z "$ing_nodes" ]; then
    no "no ingress-nginx controller pods found"
elif [ "$ing_nodes" = "$INFRA_NODE" ]; then
    ok "ingress-nginx controller is on ${INFRA_NODE}"
else
    no "ingress-nginx controller is on: $(tr '\n' ' ' <<<"$ing_nodes") — expected ${INFRA_NODE}"
    note "it needs BOTH the toleration and the nodeSelector; a toleration alone"
    note "lets it past the taint without putting it anywhere in particular"
fi

# PROXY protocol, which Week09 stage 5 turned on so the application could log
# real client IPs. Nothing this week needs them, and the load generator speaks
# plain HTTP to the controller's ClusterIP — so left on, every request it sends
# fails, and it fails looking like an application fault rather than a routing
# one. Stage 1.5 turns it off and 1.9 removes HAProxy's half of it.

proxy_proto=$(kubectl -n ingress-nginx get configmap ingress-nginx-controller \
    -o jsonpath='{.data.use-proxy-protocol}' 2>/dev/null)

case "$proxy_proto" in
    "true")
        no "ingress-nginx still has use-proxy-protocol=true"
        note "the load generator does not send a PROXY header, so every request"
        note "it makes will fail. Re-run the helm upgrade in step 1.5 with"
        note "--set-string controller.config.use-proxy-protocol=false"
        ;;
    "false"|"")
        ok "ingress-nginx is not expecting PROXY protocol"
        ;;
    *)
        warned "use-proxy-protocol is '${proxy_proto}', which is neither true nor false"
        ;;
esac

# The HAProxy half, checked only if this script can see the file. It runs on the
# rancher VM, so usually it can.

if [ -r /etc/haproxy/haproxy.cfg ]; then
    if grep -q 'send-proxy' /etc/haproxy/haproxy.cfg; then
        no "haproxy.cfg still sends PROXY protocol (send-proxy-v2)"
        note "with the controller no longer expecting it, nginx reads the PROXY"
        note "header as the request line and answers 400. Step 1.9 says to remove"
        note "it from backend be_http's server lines"
    else
        ok "haproxy.cfg does not send PROXY protocol"
    fi
else
    warned "cannot read /etc/haproxy/haproxy.cfg — skipping the HAProxy half of this check"
fi

# --------------------------------------------------------------------------
hr "4. the ResourceQuota"
# --------------------------------------------------------------------------
#
# It bounds limits, not requests. That is what makes pod size and pod count
# trade against each other.

if ! kubectl get namespace "$STUDENT_NS" >/dev/null 2>&1; then
    no "namespace '${STUDENT_NS}' does not exist"
else
    q_cpu=$(kubectl -n "$STUDENT_NS" get resourcequota \
        -o jsonpath='{.items[*].spec.hard.limits\.cpu}' 2>/dev/null)
    q_mem=$(kubectl -n "$STUDENT_NS" get resourcequota \
        -o jsonpath='{.items[*].spec.hard.limits\.memory}' 2>/dev/null)
    q_rcpu=$(kubectl -n "$STUDENT_NS" get resourcequota \
        -o jsonpath='{.items[*].spec.hard.requests\.cpu}' 2>/dev/null)

    if [ -z "$q_cpu" ] && [ -z "$q_mem" ]; then
        no "no ResourceQuota bounding limits in '${STUDENT_NS}'"
        if [ -n "$q_rcpu" ]; then
            note "a quota on requests.cpu (${q_rcpu}) was found instead — that is the"
            note "wrong one: it puts the pod wall at five instead of three"
        fi
    else
        [ "$q_cpu" = "1500m" ] && q_cpu="1.5"
        if [ "$q_cpu" = "1.5" ]; then
            ok "quota limits.cpu = 1.5"
        else
            no "quota limits.cpu = '${q_cpu}', expected 1.5"
        fi
        if [ "$q_mem" = "384Mi" ]; then
            ok "quota limits.memory = 384Mi"
        elif [ "$q_mem" = "768Mi" ]; then
            warned "quota limits.memory = 768Mi — the pre-argued fallback, not the default"
        else
            no "quota limits.memory = '${q_mem}', expected 384Mi"
        fi
    fi
fi

# --------------------------------------------------------------------------
hr "5. Argo CD reconciliation interval"
# --------------------------------------------------------------------------
#
# The 3-minute default makes this week painful: you commit a change and then
# wait, with no way to tell a slow sync from a change that did not work.
#
# Your Epimetheus Application is not checked here. It needs your own repository
# URL, so it belongs with deploying the application rather than with setting up
# the cluster.

recon=$(kubectl -n argocd get configmap argocd-cm \
    -o jsonpath='{.data.timeout\.reconciliation}' 2>/dev/null)

if [ "$recon" = "20s" ]; then
    ok "argocd-cm timeout.reconciliation = 20s"
elif [ -z "$recon" ]; then
    no "argocd-cm timeout.reconciliation is unset — the 3-minute default applies"
    note "kubectl -n argocd patch configmap argocd-cm --type merge \\"
    note "  -p '{\"data\":{\"timeout.reconciliation\":\"20s\"}}'"
    note "then: kubectl -n argocd rollout restart deployment/argocd-repo-server"
else
    warned "argocd-cm timeout.reconciliation = ${recon}, expected 20s"
fi

# --------------------------------------------------------------------------
hr "6. storage for Pandora's run history"
# --------------------------------------------------------------------------
#
# Checked before Pandora itself, because a missing provisioner leaves the claim
# Pending and the pod never starts — and "pod not running" is a much more
# confusing symptom than "no storageclass".

if kubectl get storageclass local-path >/dev/null 2>&1; then
    ok "storageclass 'local-path' exists"
else
    no "storageclass 'local-path' not found — Pandora's PVC will stay Pending"
    note "available: $(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)"
fi

pvc_phase=$(kubectl -n "$PANDORA_NS" get pvc pandora-runs \
    -o jsonpath='{.status.phase}' 2>/dev/null)

case "$pvc_phase" in
    Bound)   ok "PVC pandora-runs is Bound" ;;
    "")      no "PVC pandora-runs not found in namespace ${PANDORA_NS}" ;;
    *)       no "PVC pandora-runs is ${pvc_phase}, expected Bound"
             note "without it a pod restart erases the pair's whole run history" ;;
esac

# --------------------------------------------------------------------------
hr "7. Pandora"
# --------------------------------------------------------------------------

p_ready=$(kubectl -n "$PANDORA_NS" get deploy pandora \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)

if [ "${p_ready:-0}" -ge 1 ] 2>/dev/null; then
    ok "Pandora is running and ready"
else
    no "Pandora is not ready (readyReplicas=${p_ready:-0})"
    note "kubectl -n ${PANDORA_NS} get pods"
fi

p_node=$(kubectl -n "$PANDORA_NS" get pods -l app.kubernetes.io/name=pandora \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u | grep -v '^$')

if [ -z "$p_node" ]; then
    : # already reported as not ready
elif [ "$p_node" = "$INFRA_NODE" ]; then
    ok "Pandora is on ${INFRA_NODE}"
else
    no "Pandora is on ${p_node}, expected ${INFRA_NODE}"
fi

# Your team name, from your row on the sign-up sheet. This only checks that the
# placeholder was replaced — the load generator's own preflight will tell you if
# the name is misspelled or capitalised differently from the roster.
team=$(kubectl -n "$PANDORA_NS" get deploy pandora \
    -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}' 2>/dev/null \
    | grep -A1 -x -- '--team' | tail -1)

case "$team" in
    ""|"--team")               no "Pandora has no --team set" ;;
    REPLACE_WITH_ROSTER_NAME)  no "Pandora --team is still the placeholder"
                               note "set it to your team name from the sign-up sheet row" ;;
    *)                         ok "Pandora --team is set: ${team}"
                               note "not verified here — Pandora's preflight checks it against the roster" ;;
esac

# --------------------------------------------------------------------------
hr "8. the Pandora front door"
# --------------------------------------------------------------------------
#
# HAProxy runs on the rancher VM, which is where you are running this, so
# localhost is the honest test: it exercises HAProxy -> NodePort -> Pandora,
# everything except the ipa.local lookup, which happens on your own PC and not
# here.
#
# This is a WARN and never a FAIL. A broken frontend costs you a convenient URL,
# not the lab — you can always reach the UI at a worker's address on port 30900.

if ! command -v curl >/dev/null 2>&1; then
    warned "curl not available; skipping the front-door check"
elif curl -sf -o /dev/null --max-time 5 "http://localhost:9900/healthz" 2>/dev/null; then
    ok "HAProxy forwards :9900 to Pandora (tested on localhost)"
    note "from your own PC this is http://ipa.local:9900"
elif curl -sf -o /dev/null --max-time 5 "http://ipa.local:9900/healthz" 2>/dev/null; then
    ok "Pandora's UI answers at http://ipa.local:9900"
else
    warned "nothing answered on port 9900"
    note "if you are on the rancher VM, check the fe_pandora frontend in"
    note "/etc/haproxy/haproxy.cfg and that haproxy restarted cleanly"
    note "if you are elsewhere, ipa.local only resolves on a PC with the hosts entry"
fi

# --------------------------------------------------------------------------
echo
printf -- '---- result ------------------------------------------------------\n'
w_label=warnings
[ "$warn" -eq 1 ] && w_label=warning
printf '%d passed, %d failed, %d %s\n' "$pass" "$fail" "$warn" "$w_label"

if [ "$fail" -gt 0 ]; then
    echo
    printf '%sYour cluster is NOT ready.%s Fix the FAIL lines above and run this again.\n' \
        "$C_FAIL" "$C_OFF"
    exit 1
fi

echo
printf '%sYour cluster looks ready.%s\n' "$C_PASS" "$C_OFF"
[ "$warn" -gt 0 ] && echo "Warnings above are worth reading but do not block the lab."
exit 0
