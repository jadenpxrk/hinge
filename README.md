<p align="center">
  <img src="Design/Hinge-icon.png" width="112" alt="Hinge app icon">
</p>

<h1 align="center">Hinge</h1>

<p align="center">Keep your Mac on when you close the lid.</p>
<p align="center">Apple Silicon MacBooks · macOS 14+</p>

![Hold Option when you close the lid. The Mac stays on and the screen goes off. Open the lid to stop the session.](Design/how-it-works.svg)

## Use

- **For one lid close:** Hold **⌥ Option** when you start to close the lid. Open the lid to stop the session.
- **Until you stop it:** Select **Keep Awake** in the menu bar. Select **Turn Off** to stop the session.

When you connect an external display, Hinge pauses the session. When you disconnect the last external display with the lid open, the session starts again.

## Install from source

You must have the full **Xcode** and **XcodeGen**.

```sh
git clone https://github.com/jadenpxrk/Hinge.git
cd Hinge
make install
open /Applications/Hinge.app
```

After you update Hinge, quit Hinge and open it again.

## Safety

- Battery protection stops the session at **10%**. You can change this value in Settings.
- If the Mac becomes too hot, Hinge stops the session. **Keep the Mac in an area with good airflow. Do not put it in a bag.**
- Hinge uses an undocumented macOS API. A macOS update can change how Hinge operates.

[Technical reference](docs/REFERENCE.md) · [MIT license](LICENSE)
