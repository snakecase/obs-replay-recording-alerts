<div align="center">

<img src="images/icon.png" alt="" width="128">

# Replay & Recording Alerts

[![OBS Studio Lua script](https://img.shields.io/badge/OBS%20Studio-Lua%20script-302E31?logo=obsstudio&logoColor=white)](https://obsproject.com/)
[![Windows | macOS | Linux](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey)](#notes)
[![License: CC0-1.0](https://img.shields.io/badge/license-CC0--1.0-blue)](LICENSE)

</div>

An [OBS Studio](https://obsproject.com/) Lua script that plays a sound, shows a toast notification, or both, when you save a replay or when recording, streaming, the replay buffer or screenshots start, stop or save.

![The script's settings in OBS's Scripts window](images/screenshot.png)

- Each event has its own sound, volume and toast. For saves, the toast shows the file name.
- Sounds play on OBS's **Monitoring Device** and stay out of recordings, unless Desktop Audio captures that device (see below).
- Optionally record a sound to an audio track. A track other than 1 keeps a separate copy most video players won't play.

## Installation

1. Download this repository. Keep the `.lua` and `.wav` files in the same folder.
2. In OBS, open **Tools → Scripts**, click **+** and pick `Replay & Recording Alerts.lua`.
3. Enable the events you want and press **Test**.

## Keeping sounds out of recordings

Desktop Audio records everything on its device. If your Monitoring Device is the same device, the sounds get recorded too, and the script shows a warning.

To fix it, pick another device in **Settings → Audio → Advanced → Monitoring Device** (for example, headphones while Desktop Audio captures speakers). Or capture game audio with **Application Audio Capture** instead of Desktop Audio.

## Notes

- **Windows:** toasts come from *OBS Studio*, or from *Windows PowerShell* for a portable OBS. A new toast replaces the previous one.
- **macOS:** toasts come from *Script Editor*. Allow its notifications in System Settings → Notifications.
- **Linux:** toasts need `notify-send` (`libnotify-bin` or `libnotify`), which the Flatpak OBS lacks.
- Only tested on Windows.

## Reporting problems

Before opening an [issue](../../issues), reproduce the problem and attach your OBS log (**Help → Log Files → Upload Current Log File**). The script logs each event and any toast errors there.

## Credits

- Based on the [*Beep on replay buffer save*](https://gist.github.com/snakecase/e816384a071cec31efbb4b9e429c108d) script.
- The default sound is the City Scanner camera shutter from *Half-Life 2* (© Valve Corporation).

## License

The script is dedicated to the public domain under [CC0 1.0](LICENSE). The default sound belongs to Valve and is not covered.
