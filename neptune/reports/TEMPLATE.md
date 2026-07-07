# Drill report: N-XXX — <short title>

## Status
Pass / Fail / Partial

## What was drilled
Ship spec (name, arch, cpus/mem/disk), commit tested (`git -C ~/shipyard log
--oneline -1` on the fresh ship, not assumed).

## Results against the request's checklist
Go item by item from the request — real command output or `tmux
capture-pane` excerpts, not a paraphrase.

## Bugs found (if any)
Exact repro, exact error text. Neptune does not fix shipyard code — that's
the Shipwright's job. Report the fact, don't patch it.

## Ship disposition
Confirm destroyed (`multipass list` showing it's gone) or, if kept running
for further investigation, say so explicitly and why.
