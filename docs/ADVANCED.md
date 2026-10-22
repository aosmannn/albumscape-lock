# Albumscape Lock: advanced setup and settings

Your music, full screen on the Mac lock screen. The Mac companion to [Albumscape for Windows](https://github.com/aosmannn/albumscape).

When a song plays in **Spotify** or **Apple Music** and you lock your Mac, Albumscape Lock shows:

- the album's **animated cover** (Apple Music motion art), or the song's **music video**, or the **cover** full screen
- the **date and time**, and **synced lyrics** (from [LRCLIB](https://lrclib.net)) that fill in word by word
- a small **player** (click the picture): play/pause, next/back, a progress bar in the album's colour, and a **Liquid Glass** card
- your **liked songs** heart, if you connect Spotify

On your desktop it can also play the animated cover behind your icons, and put the still cover on the lock screen wallpaper for albums with no animation.

> Personal-use software. It draws over the lock screen with **private macOS (SkyLight) calls**, and reads Apple Music's public web pages for the animations, so a macOS update or an Apple change can break it. It is not on the App Store.

## Install

**Requirements:** macOS 14 or newer (Liquid Glass drawing works everywhere; macOS 26 recommended).

### Download

1. Download `AlbumscapeLock-mac.zip` from the [latest release](https://github.com/aosmannn/albumscape-lock/releases/latest) and unzip it.
2. Move `AlbumscapeLock.app` to `~/Applications`.
3. The app isn't notarized, so macOS blocks the first launch. Remove the block once:
   ```bash
   xattr -dr com.apple.quarantine ~/Applications/AlbumscapeLock.app
   ```
4. Open it. It lives in the menu bar (a music-note TV icon). Allow **Automation** for Spotify / Music when macOS asks.

### Build from source

You need Xcode (for the Swift toolchain).

```bash
git clone https://github.com/aosmannn/albumscape-lock.git
cd albumscape-lock
./build-app.sh        # makes AlbumscapeLock.app next to the script
open AlbumscapeLock.app
```

## Using it

- Lock your Mac with a song playing. Click the picture to shrink it to the player; click the video to open it again.
- **Menu bar icon:** preview, open at login, Spotify setup.
- **Lyrics** show in the full-screen view; press **L** to turn them on or off (needs **Input Monitoring**: System Settings → Privacy & Security → Input Monitoring → Albumscape Lock, then reopen the app).

### Connect Spotify (liked songs and the heart)

Spotify needs an app of your own (free, 2 minutes):

1. Go to <https://developer.spotify.com/dashboard> and create an app. Tick **Web API**.
2. Add the redirect address `http://127.0.0.1:3000/api/spotify/callback` and save.
3. Under **User Management**, add your own Spotify email.
4. Menu bar icon → **Spotify client ID…** → paste the Client ID → **Connect Spotify…**.

The app reads your Liked Songs once (and every 6 hours) and keeps the list on your Mac; clicking the heart sends one request. Your password never reaches the app, and the login is kept in your Keychain. No client secret is used.

## Settings (optional)

The menu bar icon has a **Music videos** switch (off: animated covers only). In Terminal:

```bash
defaults write com.adam.albumscape-lock musicVideos -bool false         # same as the menu switch
defaults write com.adam.albumscape-lock animatedWallpaper -bool false   # no animation behind the desktop icons
defaults write com.adam.albumscape-lock coverWallpaper -bool true       # put the still cover on the lock screen wallpaper (off by default)
defaults write com.adam.albumscape-lock glassMode -string swiftui       # liquid (default), swiftui or appkit
```

## Credits

Liquid Glass drawing is a Swift port of the shader in [ybouane/liquidglass](https://github.com/ybouane/liquidglass). Lyrics from [LRCLIB](https://lrclib.net). Animated covers and covers come from Apple Music's public pages.

## License

MIT — see `LICENSE`.
