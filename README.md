# JoyCon2Mac

Native macOS support for Nintendo Switch 2 Joy-Cons over BLE, with a DriverKit
extension that exposes the pair as a system gamepad + mouse, a menu-bar/SwiftUI
GUI, and a headless daemon.

## Layout

```
joycon2-mac-driver/
├── README.md                # this file
├── LICENSE
├── CMakeLists.txt           # builds the daemon (C++/Obj-C++)
├── build_gui.sh             # builds the daemon + JoyCon2Mac.app
├── build_driver.sh          # builds the DriverKit .dext (needs Xcode)
├── build_all.sh             # daemon + GUI + dext, embeds dext in the .app
├── JoyCon2Mac/              # headless daemon (BLE + decoder + DriverKit client)
├── JoyCon2MacApp/           # SwiftUI app (sidebar UI, controller/gyro/mouse/NFC views)
├── VirtualJoyConDriver/     # DriverKit extension (composite HID gamepad/mouse/NFC)
└── docs/archive/            # historical planning notes
```

## Quick build

```bash
./build_all.sh               # everything + embed dext in JoyCon2Mac.app
open build/JoyCon2Mac.app
```

On first launch macOS will show a System Settings approval for the dext. Approve
it. After that the daemon streams gamepad/mouse reports into the virtual HID
device.

## Sub-builds

```bash
./build_gui.sh               # daemon + GUI only (no DriverKit rebuild)
./build_driver.sh            # DriverKit .dext only
```

## Troubleshooting

- **Cooldown active** — rapid reconnects put the Joy-Con in a ~3-minute sleep.
  Wait it out.
- **Gyro/accel read 0** — the IMU streaming commands are fire-and-forget per
  joycon2cpp. If they never make it, re-pair or wait for the cooldown.
- **Driver extension is missing from SystemExtensions** — run `./build_all.sh`;
  `build_gui.sh` alone does not copy the dext into the app bundle.

## References

- [joycon2cpp](https://github.com/TheFrano/joycon2cpp) — C++ BLE protocol, IMU init
- [Joy2Win](https://github.com/Logan-Gaillard/Joy2Win) — command opcodes
- [Switch2-Controllers](https://github.com/Nohzockt/Switch2-Controllers) — Python GUI
- [Switch2-Mouse](https://github.com/NVNTLabs/Switch2-Mouse) — optical sensor

## License

MIT. See LICENSE.
