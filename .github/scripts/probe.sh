#!/usr/bin/env bash
# HTTP availability probe.
#
# Each target has an expected status code. A target is FAIL only when it is bad on two consecutive
# checks RETRY_DELAY seconds apart (one re-probe absorbs a dropped packet or a brief restart); any
# FAIL exits 1, and GitHub e-mails the failed run.
#
# The target URLs live in the PROBE_TARGETS secret and are never printed: output shows labels only.
#
# Env:
#   PROBE_TARGETS  required; lines of "<expected code><TAB><label><TAB><url>"
#   CANARY         "true" adds one target that cannot pass (manual dispatch: proves the e-mail path)
#   RETRY_DELAY    seconds between check 1 and the re-probe of bad targets (default 120)
set -uo pipefail

RETRY_DELAY="${RETRY_DELAY:-120}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
TARGETS="${PROBE_TARGETS:-}"

if [[ -z $TARGETS ]]; then
    echo "::error title=Probe misconfigured::PROBE_TARGETS is empty (secret missing?)"
    exit 1
fi

expected=() labels=() urls=() first=() second=()
while IFS=$'\t' read -r code label url; do
    [[ -n $url ]] || continue
    # Mask the URL and its host before anything can print them: the secret's masking covers the
    # whole value, not each line or host taken out of it.
    host=${url#*://}
    host=${host%%/*}
    if [[ -n ${GITHUB_ACTIONS:-} ]]; then
        echo "::add-mask::$url"
        echo "::add-mask::$host"
    fi
    expected+=("$code")
    labels+=("$label")
    urls+=("$url")
done <<< "$TARGETS"

if [[ ${CANARY:-false} == true ]]; then
    # 599 is not a real status code, so this target fails on both checks whatever the server says.
    expected+=(599)
    labels+=(canary)
    urls+=("${urls[0]}")
fi

# Prints "<http_code>\t<curl exit code>".
probe() {
    local out rc
    out=$(curl -sk -o /dev/null -m 15 -w '%{http_code}' "$1" 2>/dev/null)
    rc=$?
    # curl prints the -w code even when the request fails (000), so the fallback is only for no
    # output at all; appending one regardless gives a malformed result.
    [[ -n $out ]] || out=000
    printf '%s\t%s\n' "$out" "$rc"
}

# Good = the expected code AND a clean curl exit: a response that then stalls or resets is not a
# healthy page.
good() {
    local code rc
    IFS=$'\t' read -r code rc <<< "$1"
    [[ $code == "$2" && $rc == 0 ]]
}

# The status code alone, or "err" when curl itself failed.
show() {
    local code rc
    IFS=$'\t' read -r code rc <<< "$1"
    if [[ $rc == 0 ]]; then printf '%s' "$code"; else printf 'err'; fi
}

ts=$(date -u +%FT%TZ)
bad=0
for i in "${!urls[@]}"; do
    first[i]=$(probe "${urls[i]}")
    printf '%s\t%s\t%s\n' "$ts" "${labels[i]}" "$(show "${first[i]}")"
    good "${first[i]}" "${expected[i]}" || bad=$((bad + 1))
done

if ((bad > 0)); then
    echo "$bad target(s) bad on check 1; re-probing them in ${RETRY_DELAY}s"
    sleep "$RETRY_DELAY"
    ts2=$(date -u +%FT%TZ)
    for i in "${!urls[@]}"; do
        good "${first[i]}" "${expected[i]}" && continue
        second[i]=$(probe "${urls[i]}")
        printf '%s\t%s\t%s\n' "$ts2" "${labels[i]}" "$(show "${second[i]}")"
    done
fi

fails=0 flaps=0
{
    echo "### Probe — $ts"
    echo
    echo "FAIL = bad on both checks ${RETRY_DELAY}s apart; FLAP = bad once, then good."
    echo
    echo '| Target | Expected | Check 1 | Check 2 | Result |'
    echo '|---|---|---|---|---|'
    for i in "${!urls[@]}"; do
        if good "${first[i]}" "${expected[i]}"; then
            result=OK check2='—'
        else
            check2=$(show "${second[i]}")
            if good "${second[i]}" "${expected[i]}"; then
                result=FLAP
                flaps=$((flaps + 1))
            else
                result='**FAIL**'
                fails=$((fails + 1))
            fi
        fi
        echo "| ${labels[i]} | ${expected[i]} | $(show "${first[i]}") | $check2 | $result |"
    done
} >> "$SUMMARY"

# Annotations put the verdict on the run page without opening the summary.
for i in "${!urls[@]}"; do
    good "${first[i]}" "${expected[i]}" && continue
    if good "${second[i]}" "${expected[i]}"; then
        echo "::warning title=Probe FLAP::${labels[i]} expected ${expected[i]}, got $(show "${first[i]}") then $(show "${second[i]}")"
    else
        echo "::error title=Probe FAIL::${labels[i]} expected ${expected[i]}, got $(show "${first[i]}") then $(show "${second[i]}")"
    fi
done

echo "probe: ${#urls[@]} targets, $fails FAIL, $flaps FLAP"
((fails == 0))
