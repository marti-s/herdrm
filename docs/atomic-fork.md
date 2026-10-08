# Atomic fork

This fork (`Marti-S/herdrm`) is upstream [`missuo/herdrm`](https://github.com/missuo/herdrm)
plus one feature: the macOS app launches and recognizes
[Atomic](https://github.com/bastani-inc/atomic) as a Pi-compatible agent. Everything
else, including layout, the iOS app and CI, is upstream's.

## Syncing

`main` = `upstream/main` + the Atomic commits. Changes come in from upstream only:

```sh
git fetch upstream
git rebase upstream/main   # replay the Atomic commits on the new upstream
```

The Atomic delta stays in this fork and is not sent upstream.

## The delta

- `Packages/HerdrKit/Sources/HerdrKit/HerdrService.swift`: `runShellCommand`,
  `startPiCompatibleAgent` and `piCompatibleShellCommand`. Atomic overwrites its
  process title, so herdr would never see `pi`. The launch writes a `pi` shell script
  into a fresh mode-0700 `${TMPDIR:-/tmp}/herdrm-agent-shims.XXXXXX` directory. The
  script deletes that directory, then runs the resolved Atomic binary as its child, so
  closing the pane leaves nothing behind. The `/bin/sh …/pi` command line stays in the
  pane's process list, and herdr classifies the pane as `pi`.
- `Sources/HerdrM/AppModel.swift`:
  - `insertingAtomic` lists `atomic` after `pi` in the New Agent picker when herdr
    advertises `pi`. Local devices need the binary or a Settings override; SSH hosts
    are not checked until launch.
  - `startNewAgent` launches `atomic` through the shim and remembers the pane.
  - `agentDisplayKind` reports `atomic` only for Pi agents: launched panes, or panes whose
    tab label, name or title is `atomic`/`atomic-…`.
  - `agentDisplayStatus` marks such panes working while Atomic's loader shows, and
    never overrides herdr's blocked status.
- `Sources/HerdrM/AtomicActivityDetector.swift`: scans visible `pane.read` rows
  (CRLF/ANSI-aware) for Atomic's separately styled `∀` loader glyph. The persistent
  `∀ Continued in background` transcript row does not count.
- `Sources/HerdrM/SidebarView.swift`: agent rows use the display kind/status and poll
  `refreshAtomicActivity` every 750 ms (a no-op for other agents).
- `BrandIcon.swift`: `atomic` uses the Pi icon. `HerdrMApp.swift`: Settings → Agents
  has an Atomic binary override.
- Tests: `Packages/HerdrKit/Tests/HerdrKitTests/PiCompatibleLaunchTests.swift`
  (its live test opens and closes a `herdrm-test` tab on the local herdr socket) and
  `Tests/HerdrMTests/AtomicAgentTests.swift`.

## Known limits

- The launch types POSIX shell syntax into the pane's login shell; fish, nushell and
  PowerShell hosts are unsupported. A missing binary exits 127 and closes that shell.
- With `NO_COLOR` the loader glyph is unstyled and indistinguishable from transcript
  text, so herdr's own status applies.
