After committing changes, immediately push the commit to GitHub so the user can see it.

Never run the simulator UI tests (`.github/workflows/ui-tests.yml`, "Exhaustive
iOS Simulator UI Tests", the `MossLiveUITests` scheme) on your own. A single run
takes ten minutes or more, which is far too slow to work with. Only start one if
the user explicitly asks for it in that message.

To check a change, use the `CI` workflow instead: it builds and runs the unit
tests in a couple of minutes.

    gh workflow run ci.yml -R 4MBs/echo-ios --ref <branch> -f run_unit_tests=true

Keep writing XCUITests when a change deserves one — they are part of the suite
the user runs when they want it. Just do not dispatch them yourself.
