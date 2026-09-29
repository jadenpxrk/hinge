# Technical reference

[Back to the quick start](../README.md)

## Safety and gesture behavior

Battery protection stops at 10% by default. Settings offers Off and thresholds from 5% through 50% in 5% steps. Users who already chose Off keep that setting. While on battery, crossing the selected threshold ends the awake session. A deliberate arm at or below the threshold is allowed above 0%, but the session ends if charge drops below the level at which it was armed. A reported 0% blocks or ends a protected battery session. On AC, low charge does not stop work. If protected battery telemetry is unavailable for 15 seconds, an active session ends; a new protected session requires valid telemetry.

Serious or critical thermal pressure always ends the session and blocks re-arming until the Mac cools. Power-source and thermal notifications trigger checks immediately, with a five-second polling fallback. After a safety stop with the lid closed and no external display, Hinge asks macOS to sleep. Clearing Hinge's change already makes the kernel re-run its own lid-closed sleep decision; the explicit sleep request needs a login session, and when it is refused (for example a headless `--on` over SSH with nobody logged in) Hinge re-triggers that kernel decision instead. Failed restoration or sleep requests remain visible and retryable. A paused session ends without a sleep request because Hinge was not holding the Mac awake. Safety stops never automatically re-arm.

Idle gesture monitoring checks the modifier key at 10 Hz without reading the hinge sensor. While Option is held, it samples at 40 Hz, requires a steady hold and consistent closing motion, and rejects implausible jumps. Sensor failures reset motion history and reconnect attempts are limited to once per second. Sleep/wake restarts gesture monitoring.

Arming shows a brief confirmation on the built-in display only, with no all-display dimming. It does not create a replacement lock screen or alter authentication settings. Follow Apple's [password-after-display-off settings](https://support.apple.com/en-gb/guide/mac-help/mchlp2270/mac) to require a password immediately.

## Sleep control and recovery

Hinge uses the unprivileged `kPMSetClamshellSleepState` IOKit SPI (selector 12). It has no administrator setup or privileged fallback. An additional idle-sleep assertion prevents the idle timer from putting the Mac to sleep. No display-sleep assertion is taken.

The SPI changes a shared system bit; it is not a process-scoped assertion. Apple's [RootDomainUserClient implementation](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/RootDomainUserClient.cpp) is the reference. A successful call is not a guarantee that another application or macOS cannot change the setting afterward. Avoid running multiple lid-control utilities at once. Run Hinge in one macOS account at a time; each account has its own session lock. The SPI is undocumented and may change in future macOS versions.

Each Hinge session, including a paused one, holds an exclusive file lock in a private, user-owned recovery directory. Other Hinge processes cannot claim the same session. CLI stop commands request restoration from the owner and wait for it to release the session; they do not signal a PID or race the owner's reassertion timer.

Before changing sleep behavior, Hinge writes a recovery record and verifies that its LaunchAgent is loaded. The agent checks every 20 seconds and at login. After a crash releases the file lock, the agent restores only the backend recorded by Hinge. Failed restores retain the record for another attempt. The watchdog leaves system settings alone when there is no ownership record. Crash recovery is therefore not instantaneous, and it requires the installed executable and a working user launchd session.

Keep the executable at its installed path so the watchdog can find it.

The private recovery directory protects against other local accounts. It is not a security boundary against software already running as your account or as root.

## Build and checks

Requires full Xcode and XcodeGen. The installed command-line tools must point to Xcode. No Python or downloaded test dependencies are required.

```sh
make check       # regression checks plus a signed local app, without installing
make             # build Hinge.app locally
make install     # build and copy to /Applications/Hinge.app
open /Applications/Hinge.app
```

Installation copies and verifies the new bundle beside the destination, then atomically swaps it with the existing app. A failed copy or signature check leaves the existing app intact. Quit and reopen Hinge after updating to run the new version.

`make test` runs the regression checks separately. The checks compile the actual engine, storage, watchdog, and menu with simulated hardware and system commands. File locks, competing processes, crashes, recovery files, external-display pausing and paused-session ownership, safety policies, gesture filtering, command ordering, and main-thread responsiveness have regression coverage. `SystemAccess.swift` and `IOPM.swift` form the production boundary; tests supply isolated implementations without modifying or copying production source. Tests do not change actual sleep settings or administrator permissions.

Both the build script and Xcode use the project generated from `project.yml` and the same `Hinge/Info.plist`:

```sh
make project
open Hinge.xcodeproj
```

The app icon is the editable Icon Composer document at `Hinge/Hinge.icon`. Its transparent logo artwork is in `Assets/Hinge.png` inside that document. Open it in Icon Composer to adjust the background, placement, or appearance. Exported previews are in `Design/`. Xcode compiles the document into the app's asset catalog and generates the `.icns` fallback for older macOS versions.

## Commands

The binary is `Hinge.app/Contents/MacOS/Hinge`:

```text
Hinge                  Menu-bar app
Hinge --on             Arm persistently and wait
Hinge --off            Ask the owner to restore sleep and wait for confirmation
Hinge --toggle         Stop a recorded session, or start a headless session
Hinge --status         Read system settings and recorded recovery state
Hinge --probe          Read-only connection and hinge-sensor diagnostics
Hinge --restore-sleep  Restore only changes owned by Hinge
Hinge --watchdog       Run one recovery check
```

A timeout or restoration failure exits nonzero. Stop commands leave unrelated sleep settings unchanged.

URL commands are `hinge://arm`, `hinge://disarm`, and `hinge://toggle`. Links that would arm require confirmation so a website cannot silently start an awake session. The app also defines Arm, Disarm, Toggle, and Status App Intents.

## Hardware acceptance check

On a ventilated desk, with no external display attached:

1. Arm using the menu, then close the lid.
2. From another machine, confirm an SSH connection still works and `date` advances.
3. Open the lid; verify the menu-started session remains active, then turn it off.
4. Arm again, then run `--off` from a separate terminal. Wait more than five seconds and verify it stays off.
5. Verify connecting an external display pauses the session and disconnecting the last external display with the lid open resumes it.
6. Verify the gesture still works after sleep/wake. The confirmation must never cover an external display.
7. Set macOS to require a password immediately after display-off. Arm, close, and reopen; verify the real macOS authentication screen appears. Also test Control–Command–Q while armed. Do not treat the confirmation panel as evidence of locking.
8. Test battery protection with a threshold above the current charge while unplugged, including the switch from AC to battery. Do not intentionally overheat the Mac to test thermal protection; automated tests simulate the reported thermal state.

`SleepDisabled` normally remains absent or zero on the SPI path. `AppleClamshellCausesSleep` can be stale until a lid event; it is not a reliable immediate verification of an SPI write.

## Remove

Turn off and quit Hinge first. If it reports a restoration failure, resolve that before removing the recovery agent. Then:

```sh
launchctl bootout gui/$UID/dev.hinge.watchdog
rm -f ~/Library/LaunchAgents/dev.hinge.watchdog.plist
rm -rf ~/Library/Application\ Support/Hinge
rm -rf /Applications/Hinge.app
```
