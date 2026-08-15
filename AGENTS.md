# iOS workflow

## Every change goes through a pull request

Never commit to `main` and never push to it. Work on a branch, then open a pull
request and let it be merged from there. This is not a style preference: work
that sits on a branch without a PR silently diverges from `main`, and the fixes
on either side then have to be reconciled by hand later. If you have pushed a
branch, you are not finished — open the PR.

    git switch -c feature/<short-name>
    # commit, then push so the user can see the work
    git push -u origin feature/<short-name>
    gh pr create -R 4MBs/echo-ios --base main --fill

Before opening it, bring the branch up to date with `main` and resolve any
conflict there rather than leaving it for the merge. Say in the PR body what
changed and how it was checked.

Do not merge your own PR unless the user asks you to. Opening it is the
deliverable; the user decides when it lands.

One branch is one topic. Do not stack an unrelated second feature onto a branch
that is already waiting for review — it makes the PR unreviewable and drags
work that was ready to merge along behind work that is not.

## Checking a change

A pull request runs the `CI` and `Lint` workflows on its own. That is the
intended way to check a branch, so do not dispatch `ci.yml` by hand as well —
it bills the same macOS minutes twice for the same commit. (`CI` is a macOS
job and macOS minutes bill at 10x on a private repo; `Lint` is cheap Linux.)

Only when there is a reason to check something before the PR exists:

    gh workflow run ci.yml -R 4MBs/echo-ios --ref <branch> -f run_unit_tests=true

## Never run the simulator UI tests on your own

`.github/workflows/ui-tests.yml` ("Exhaustive iOS Simulator UI Tests", the
`MossLiveUITests` scheme) takes ten minutes or more per run, which is far too
slow to work with. Only start one if the user explicitly asks for it in that
message.

Keep writing XCUITests when a change deserves one — they are part of the suite
the user runs when they want it. Just do not dispatch them yourself.

## Building the IPA

The user builds and installs the IPA themselves. Do not produce one, and do not
kick off a release build, unless you are asked for it.
