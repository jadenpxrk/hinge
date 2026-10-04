# Technical reference

[Back to the quick start](../README.md)

## Safety

Battery protection stops the session at 10% charge. In Settings, you can select Off or a value from 5% to 50%, in 5% steps. On battery power, the session stops when the charge decreases to the value that you select.

You can start a session when the charge is at or below the selected value. That session stops if the charge decreases below the charge at the start. When battery protection is on and the battery shows 0%, Hinge does not start a session. It also stops a session that operates. On AC power, Hinge does not monitor the charge.

If Hinge cannot read the battery status for 15 seconds, the session stops. Hinge does not start a new session until it can read the battery status.

If the thermal state of the Mac is serious or critical, the session stops. You cannot start a new session until the Mac becomes cooler. Hinge checks the power source and the thermal state when they change, and every 5 seconds.

When a safety check stops the session, the lid is closed, and no external display is connected, Hinge puts the Mac to sleep. Hinge does not start the session again after a safety stop. If Hinge cannot restore lid sleep, the menu shows an error and Hinge tries again at each check.

## Gesture and external displays

When you hold Option and close the lid, Hinge starts a session. The session stops when you open the lid. You must hold Option and close the lid in one continuous movement. If you do not close the lid in 30 seconds, the session stops. Hinge reads the hinge sensor only while you hold Option.

When an external display is connected, Hinge pauses the session, and macOS controls lid sleep. When you disconnect the last external display with the lid open, the session starts again. When a paused session stops, Hinge does not put the Mac to sleep.

When a session starts, Hinge shows a short message on the built-in display. Hinge does not lock the Mac and does not change the password settings. To set a password when the display goes off, refer to Apple's [password-after-display-off settings](https://support.apple.com/en-gb/guide/mac-help/mchlp2270/mac).

## Sleep control and recovery

Hinge uses the undocumented `kPMSetClamshellSleepState` IOKit call (selector 12) to disable lid sleep. This call does not need administrator rights. Hinge also holds an idle-sleep assertion, so the idle timer cannot put the Mac to sleep. Hinge does not keep the display on. For the source of the IOKit call, refer to Apple's [RootDomainUserClient source](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/RootDomainUserClient.cpp).

The lid setting applies to the full system, not only to the Hinge process. Other apps and macOS can change it. Do not use other lid-control apps at the same time as Hinge. Use Hinge in only one macOS account at a time.

Each session holds a lock in `~/Library/Application Support/Hinge`, also when the session is paused. Thus, only one Hinge process can control the session. A stop command tells this process to restore lid sleep, and then waits until the process completes it.

Before Hinge changes the lid setting, it writes a recovery record. It also makes sure that its LaunchAgent, `dev.hinge.watchdog`, operates. The LaunchAgent starts when you log in, and then every 20 seconds. If the Hinge process stops unexpectedly, the LaunchAgent restores the setting in the record. The LaunchAgent does not change settings that Hinge did not record.

Recovery can take up to 20 seconds. For recovery, Hinge must stay at the path where you installed it. The recovery folder is private to your macOS account. It does not give protection from other software that operates as your account or as root.

## Build and test

You must have the full Xcode and XcodeGen. Run `xcode-select` to make sure that the command-line tools use Xcode.

```sh
make check       # tests, then build a signed app without installing
make             # build Hinge.app locally
make install     # build and install to /Applications/Hinge.app
make test        # tests only
```

`make install` copies the new app next to `/Applications/Hinge.app` and checks its signature. Then it swaps the two apps in one atomic operation. If the copy or the signature check fails, the installed app does not change. After you update Hinge, quit Hinge and open it again.

`make test` compiles the engine, storage, watchdog, and menu code with simulated hardware. `Tests/SystemStubs.swift` replaces `SystemAccess.swift` and `IOPM.swift`. The tests do not change the sleep settings of your Mac.

To use Xcode, run `make project`, and then open `Hinge.xcodeproj`. The app icon is `Hinge/Hinge.icon`. To change it, use Icon Composer. Exported previews are in `Design/`.

## Commands

The binary is `Hinge.app/Contents/MacOS/Hinge`:

```text
Hinge                  Menu-bar app
Hinge --on             Start a session. Wait until you stop it or the session stops.
Hinge --off            Tell the owner to restore lid sleep. Wait for confirmation.
Hinge --restore-sleep  Same as --off
Hinge --toggle         Do --off if a session exists. If not, do --on.
Hinge --status         Show the lid, sleep, battery, and recovery state
Hinge --probe          Show connection and hinge-sensor data. Change nothing.
Hinge --watchdog       Do one recovery check (the LaunchAgent uses this)
```

If a command times out or cannot restore lid sleep, it exits with a nonzero status.

The URL commands are `hinge://arm`, `hinge://disarm`, and `hinge://toggle`. Before a link starts a session, Hinge asks you to confirm. Thus, a website cannot start a session without your approval. In Shortcuts, Hinge gives Arm, Disarm, Toggle, and Status actions.

In the `--status` output, `SleepDisabled` shows the `pmset disablesleep` setting. Hinge does not change this setting. `AppleClamshellCausesSleep` can show an old value until the next lid event. Thus, it does not immediately confirm a change.

## Hardware check

Put the Mac on a desk with good airflow. Disconnect all external displays.

1. Select Keep Awake in the menu. Then close the lid.
2. From a different computer, connect to the Mac with SSH. Make sure that `date` shows the time increase.
3. Open the lid. Make sure that the session continues. Then select Turn Off.
4. Start a session again. In a different terminal, run `--off`. Wait more than 5 seconds. Make sure that the session stays off.
5. Connect an external display. Make sure that the session pauses. Open the lid and disconnect the display. Make sure that the session starts again.
6. Put the Mac to sleep and wake it. Make sure that the gesture operates. Make sure that the start message does not show on an external display.
7. In macOS, set a password requirement immediately after the display goes off. Start a session, then close and open the lid. Make sure that the macOS login screen shows. Also, push Control–Command–Q while a session operates.
8. Disconnect AC power. Set a battery value above the current charge. Make sure that the session stops. Also do this test when you change from AC power to battery power.

Do not make the Mac hot to test thermal protection. The automated tests simulate the thermal state.

## Remove

Stop the session and quit Hinge. If Hinge shows a restore error, correct the error before you remove the LaunchAgent. Then run these commands:

```sh
launchctl bootout gui/$UID/dev.hinge.watchdog
rm -f ~/Library/LaunchAgents/dev.hinge.watchdog.plist
rm -rf ~/Library/Application\ Support/Hinge
rm -rf /Applications/Hinge.app
```
