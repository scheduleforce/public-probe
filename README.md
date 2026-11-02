# public-probe

An external HTTP availability probe that runs on GitHub Actions.

## What it checks

Each run sends unauthenticated GETs to every target in the `PROBE_TARGETS` secret. It compares
each target's status code with the code expected for it.

A result is good only when the code matches **and** the request completes cleanly. Each request
has a 15 s timeout.

| Result | What happened | Effect |
|---|---|---|
| **OK** | good on the first check | none |
| **FLAP** | bad, then good when re-probed 2 minutes later | warning on the run page |
| **FAIL** | bad on both checks | the run fails and GitHub e-mails the failed run |

Every run writes a per-target table to its job summary. Targets appear by label only; the URLs
stay in the secret and are never printed.

## Schedule (UTC)

- **11:07–01:52:** every 15 min.
- **02:37–10:37:** hourly.

GitHub's scheduler is best-effort, so runs can start late. The `deadman` job fails any run that
finds more than 3 h since the previous scheduled run.

Scheduled-run failure e-mail goes to the user who last changed a `cron:` line in
`.github/workflows/probe.yml`.

## Renewal: the 60-day rule

GitHub disables scheduled workflows in a public repository after 60 days with no repository
activity. A disabled probe is silent: nothing runs, so nothing fails.

- **Renew** at least every 50 days with a commit to `main`.
- **Already disabled?** Run `gh workflow enable probe.yml`. Whoever re-enables it becomes the
  failure e-mail recipient.

## Outside check

Nothing inside the workflow can notice that the workflow is not running, so check from outside.
No token is needed:

```sh
curl -fsS https://api.github.com/repos/scheduleforce/public-probe/actions/workflows/probe.yml | jq -r .state
curl -fsS 'https://api.github.com/repos/scheduleforce/public-probe/actions/runs?event=schedule&per_page=1' \
  | jq -r '.workflow_runs[0] | "\(.created_at) \(.conclusion)"'
```

Expect `active`, and a run created less than 2 h ago.

## Canary

Run this check after a merge, and after any change to notifications or e-mail routing.

1. Go to Actions → Probe → **Run workflow**, tick **canary**, and run it. This adds a target that
   cannot pass.
2. After about 2½ minutes the run turns red. Confirm the failed-run e-mail arrived where it is
   read.

## Changing the targets

`PROBE_TARGETS` has one target per line: `<expected code><TAB><label><TAB><url>`. Replace it from
stdin:

```sh
gh secret set PROBE_TARGETS -R scheduleforce/public-probe < targets.tsv
```

## Local run

```sh
PROBE_TARGETS=$'200\tlocal\thttp://127.0.0.1:8080/' RETRY_DELAY=5 bash .github/scripts/probe.sh
```
