# DX.3 — The lab's Dex check survives a restart

Story: `docs/roadmap.md` DX.3 (status must be 👍 Approved before this
doc is implemented). Acceptance: none (lab tooling; it guards the lab that
every live acceptance scenario runs on).

## Why (one paragraph)

`make lab-dex` restarts Dex and then runs one `wget` from the Vault pod to
prove that Vault reaches Dex's issuer. The `wget` has no timeout and no retry.
In the smoke run of 2026-11-06, on a new lab, that connection went to the old
Dex pod's address while kube-proxy still had it, hung for the kernel's connect
timeout (about 127 s) and failed the lab build. Dex answered when it was probed
again. CI runs `make e2e-kind` on a new lab each time, so a red Kind E2E run can
be this race and not a defect.

## Governing constraints

- CLAUDE.md, the test harness rules inherited from Enterprise: no check that
  can pass on its own failure. A retry must not turn "Dex never answers" or
  "Dex answers as another issuer" into a pass.
- CLAUDE.md, "a new guard adds its mutation": the check's rules are guards, so
  each gets a mutation in `hack/mutation_tests.py`.
- No CLAUDE.md invariant on the charts applies: the charts do not change.

## Design

- New `hack/lab/dex-reachable.sh`, called by `lab-dex` in place of the inline
  probe. Inputs: `CONTEXT`, `KUBECTL`, `VAULT_NS`, `DEX_ISSUER`;
  `DEX_WAIT` (total seconds, default 120) and `DEX_RETRY_SLEEP` (default 3)
  for the tests.
- Each try: `kubectl exec vault-0 -- wget -T 5 -qO- <issuer>/.well-known/openid-configuration`.
  `-T 5` bounds one try, so a connection to a gone pod costs 5 s, not 127 s.
- A try that fails is tried again until `DEX_WAIT` runs out; then the script
  fails with the message `lab-dex` had: `error: the Vault pod cannot reach Dex at <issuer>`,
  and the last error.
- A try that answers with another issuer fails at once, without a retry:
  `error: Dex's issuer is not <issuer>`. A wrong issuer is a wrong config,
  not a race.
- Success prints the line `lab-dex` printed: `Dex answers as <issuer> inside the Vault pod`.
- `Makefile`: `lab-dex` calls the script with the lab's values. Nothing else
  in the lab changes.

## Tests (red first)

`hack/test_lab_dex_reachable.py` (run by `make test`), with a fake `kubectl`
on `PATH` that fails a set number of tries, then prints a discovery document:

- `test_retries_until_dex_answers`: two failed tries, then the right issuer:
  exit 0, three tries.
- `test_gives_up_when_dex_never_answers`: every try fails: exit not 0, the
  message names Dex's issuer, and the run ends within `DEX_WAIT` plus one try.
- `test_wrong_issuer_fails_at_once`: the first try answers with another issuer:
  exit not 0, the issuer message, one try only.
- `test_each_try_has_a_timeout`: the fake records its arguments: every `wget`
  has `-T`.

Red: the tests run before the script exists and fail. Mutations, each killed
by its own test: the retry loop removed (`dex-retry`), the give-up exit made
0 (`dex-give-up`), the issuer check removed (`dex-issuer`), `-T` removed
(`dex-timeout`).

Live: `make lab-dex` on the kind lab, several times in a row (each restarts
Dex), passes.

## Out of scope

The other lab probes: `chart-repo-publish.sh` probes `127.0.0.1` inside the
pod, not a Service, so it has no stale endpoint. DX.1 (CI as a merge gate).

## Done means

The roadmap Done line; `make verify` green (it runs `make test`); the four
mutations killed by `make mutation-test`; `make lab-dex` green on the lab
several times; no chart changes, so no version bump.

## Result

- Red: the four tests, run against the inline probe ported unchanged into
  the script, failed three (`retries`, `gives up`, `timeout`); `wrong issuer`
  passed, as the old probe already refused a wrong issuer.
- Green: `make verify` (34 Python tests, the Go tests, the admission cases
  109, 26 and 22).
- `python3 hack/mutation_tests.py dex-retry dex-give-up dex-issuer dex-timeout`:
  4 mutations, 4 killed by their named test.
- Live, `make lab-dex` three times in a row on the kind lab: all green, 5 s,
  5 s and 23 s. The third run hit the race (`try 1: wget: download timed
  out`) and passed on the retry; the old probe failed the lab build there.
- Each retry prints a line, so a race that the retry hid is in the log.
