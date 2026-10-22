#!/usr/bin/env bash
#
# dns-parity-check.sh — assert the secondary resolver answers identically
# to the primary (#638).
#
# WHY THIS EXISTS
# ---------------
# AdGuard (forge-ops) is primary DNS; dnsmasq (forge-hypervisor) is the
# secondary that answers when AdGuard does not. Both hold the internal
# bezaforge.dev zone, and BOTH ARE HAND-MAINTAINED — AdGuard's rewrites are
# set in its web UI and are not Ansible-managed (see roles/adguard), while
# dnsmasq's mirror lives in roles/dnsmasq/defaults/main.yml. Nothing stops
# them drifting.
#
# A drift here is invisible during normal operation, because AdGuard answers
# everything. It surfaces only during an AdGuard outage — precisely when
# nobody is in a position to debug DNS. That is why this check exists and
# why it should be run after touching EITHER side.
#
# This test has gone red for real: the first roles/dnsmasq deploy carried
# only the wildcard, and this sweep caught four host names answering
# differently. It has earned the right to be believed — but only in this
# form. See "A NOTE ON THE PREVIOUS VERSION" below.
#
# A NOTE ON THE PREVIOUS VERSION (2026-08-08)
# -------------------------------------------
# The ad-hoc shell this replaces reported a mismatch WITHOUT printing the
# two values, so when it produced a false positive on the apex there was no
# evidence left to diagnose it — the follow-up query showed the two
# resolvers agreeing 3/3. A check that cannot show its work is not a check.
# Hence: every comparison prints both answers, empty answers are treated as
# a distinct failure class from differing answers, and each query is
# retried before being believed.
#
# USAGE
#   scripts/dns-parity-check.sh              # default primary/secondary
#   scripts/dns-parity-check.sh -v           # print every name, not just failures
#   PRIMARY=10.10.20.20 SECONDARY=10.10.10.10 scripts/dns-parity-check.sh
#
# EXIT CODES
#   0  every name agrees
#   1  at least one name disagrees
#   2  at least one resolver failed to answer at all (test is INVALID —
#      this is not a pass and not a parity failure; fix the resolver first)

set -uo pipefail

PRIMARY="${PRIMARY:-10.10.20.20}"     # AdGuard on forge-ops
SECONDARY="${SECONDARY:-10.10.10.10}" # dnsmasq on forge-hypervisor
DOMAIN="${DOMAIN:-bezaforge.dev}"
RETRIES="${RETRIES:-3}"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

# Names to compare. Covers all three shapes, because the original bug was a
# SAMPLE SHAPE problem, not a sample size problem: eleven service names all
# agreed while every host name disagreed.
#
#   hosts    — expected to differ from the wildcard (explicit records)
#   services — expected to equal the wildcard (Traefik)
#   control  — a name nobody has defined; proves the wildcard still catches
#              the general case rather than the list having replaced it
NAMES=(
  # host records (explicit on both sides)
  forge-hypervisor forge-ops forge-ops-mgmt omada
  forge-ai forge-erp forge-dev
  # service names (wildcard -> Traefik)
  home traefik grafana git pm docs books erp netbox uptime langfuse
  # controls
  nope-not-real definitely-not-a-real-host
)

# NAMES_OVERRIDE lets a caller narrow the sweep to specific labels
# (space-separated, without the domain). Set it to the empty string to check
# only the bare apex. Primarily for proving this script's own failure paths:
# a check whose FAIL branch has never been exercised is not known to work.
if [ "${NAMES_OVERRIDE+set}" = "set" ]; then
  # shellcheck disable=SC2206
  NAMES=(${NAMES_OVERRIDE})
fi

query() {
  # $1 = resolver, $2 = fqdn. Retries before believing an empty answer, so a
  # single dropped UDP packet cannot masquerade as a parity failure.
  local server="$1" name="$2" out="" i
  for ((i = 0; i < RETRIES; i++)); do
    out=$(dig +short +tries=1 +time=2 "@${server}" "$name" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    sleep 0.2
  done
  return 1
}

mismatches=0
unanswered=0
checked=0

printf '%-34s %-16s %-16s %s\n' "NAME" "PRIMARY" "SECONDARY" "RESULT"
printf '%-34s %-16s %-16s %s\n' "----" "-------" "---------" "------"

for n in "${NAMES[@]}" ""; do
  # the empty element becomes the bare apex
  if [ -z "$n" ]; then fqdn="$DOMAIN"; else fqdn="${n}.${DOMAIN}"; fi
  checked=$((checked + 1))

  if ! p=$(query "$PRIMARY" "$fqdn"); then
    printf '%-34s %-16s %-16s %s\n' "$fqdn" "<NO ANSWER>" "-" "INVALID (primary silent)"
    unanswered=$((unanswered + 1)); continue
  fi
  if ! s=$(query "$SECONDARY" "$fqdn"); then
    printf '%-34s %-16s %-16s %s\n' "$fqdn" "$p" "<NO ANSWER>" "INVALID (secondary silent)"
    unanswered=$((unanswered + 1)); continue
  fi

  if [ "$p" = "$s" ]; then
    [ "$VERBOSE" -eq 1 ] && printf '%-34s %-16s %-16s %s\n' "$fqdn" "$p" "$s" "ok"
  else
    printf '%-34s %-16s %-16s %s\n' "$fqdn" "$p" "$s" "*** MISMATCH ***"
    mismatches=$((mismatches + 1))
  fi
done

echo
echo "checked=${checked}  mismatches=${mismatches}  unanswered=${unanswered}"

if [ "$unanswered" -gt 0 ]; then
  echo "RESULT: INVALID — a resolver did not answer. This is NOT a pass."
  echo "  Check both are up before reading anything into the comparison:"
  echo "    systemctl status dnsmasq            # on forge-hypervisor"
  echo "    docker ps --filter name=adguard     # on forge-ops"
  exit 2
fi
if [ "$mismatches" -gt 0 ]; then
  echo "RESULT: FAIL — the resolvers disagree. During an AdGuard outage those"
  echo "  names would resolve differently than they do today."
  echo "  Primary is authoritative: reconcile roles/dnsmasq's dnsmasq_host_records"
  echo "  against AdGuard's rewrite table, then re-run."
  exit 1
fi
echo "RESULT: PASS — all ${checked} names agree."
