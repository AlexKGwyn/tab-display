# Privacy Policy — Tab Display

_Last updated: 2026-10-04_

Tab Display (the Mac app and the Android app) does not collect, store, or share any personal data.

- **No internet access.** The apps talk to each other only over the USB cable between your Mac and your
  tablet. They make no internet connections, contain no analytics, advertising, or crash-reporting SDKs,
  and have no accounts. To install the tablet app from the Mac, the Mac app may talk to an Android
  Debug Bridge server on your own Mac (127.0.0.1) or to the tablet directly over USB.
- **Screen contents** of the Mac's virtual display are streamed over USB to your tablet for display and
  are never recorded or saved. The macOS Screen Recording permission is used only for this.
- **Pen and touch input** on the tablet is sent over USB to your Mac to control the pointer. The macOS
  Accessibility permission is used only to post these input events.
- **Local settings** (display size, quality, and the serial numbers and names of tablets you've connected,
  used to reconnect automatically) are stored on your devices only. If you install the tablet app from
  the Mac, the Mac app creates a key that identifies it to the tablet for USB debugging, stored only on
  your Mac. Diagnostic logs stay on the Mac
  (`~/Library/Logs/TabDisplay.log`).

Questions: open an issue in the project's repository.
