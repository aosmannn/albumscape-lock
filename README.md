# Albumscape Lock

**Your music, full screen on your Mac's lock screen.**
Play a song in Spotify or Apple Music, lock your Mac, and see the album's animated cover, or the music video, with the time and lyrics on top.

## Get it

1. Download **AlbumscapeLock-mac.zip** from the [latest release](../../releases/latest) and unzip it.
2. Drag **AlbumscapeLock.app** into your **Applications** folder.
3. Open **Terminal**, paste this, and press Return (it lets your Mac open the app, once):
   ```
   xattr -dr com.apple.quarantine /Applications/AlbumscapeLock.app
   ```
4. Open **AlbumscapeLock**. A small icon appears in your menu bar. Click **Allow** if your Mac asks about Spotify or Music.

That's it. Play a song and lock your Mac.

## Use it

- **Click the picture** to make it small (a player with play, next, back and sound output). Click again to go full screen.
- **Nothing playing?** Your lock screen and desktop shuffle through the animated covers of albums you've played. **Click** (or press N) to skip one.
- **Menu bar icon:** turn **Music videos** off to see only animated covers, turn the shuffle off, or **Open at login**.
- Press **L** on the lock screen for synced lyrics (see the advanced page for the one permission it needs).

Needs macOS 14 or newer. It isn't on the App Store, so a Mac update can sometimes break it.

More options (Spotify hearts, lyrics key, wallpaper): [advanced setup](docs/ADVANCED.md).

MIT license.
