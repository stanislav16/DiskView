# DiskView

A native macOS disk-space visualizer in the spirit of DaisyDisk, built with SwiftUI and Liquid Glass.

## Build & run

```bash
scripts/build.sh --run
```

This builds `build/DiskView.app` (ad-hoc signed) and installs it into `/Applications`, replacing the
previous copy. If DiskView is running, it's quit and relaunched on the new build.
Requires macOS 26+ and Xcode (the script uses `/Applications/Xcode.app` automatically).

## Features

- **Disks & folders**: scan any mounted volume, a common folder from the sidebar, or drop a folder onto the window.
- **Fast scanner**: parallel `getattrlistbulk(2)` walker; counts allocated size on disk, de-duplicates hard links, stays on one volume.
- **Interactive sunburst**: hover to inspect, click a segment to zoom in, click the centre to go up. Zooms animate as one continuous spring.
- **Synced list**: children sorted by size with matching colours; hover in either view highlights both.
- **Hidden & purgeable space**: for whole-disk scans, space macOS reports as used but no visible file accounts for.
- **Collector**: drag items (or press `C` while hovering) to gather them, see the total, then move them to the Trash with one confirmation. Items go to the Trash, so they can be restored.
- **Finder integration**: Open, Reveal in Finder, Quick Look (`Space`), Copy Path from any context menu.
- **Navigation**: Back `⌘[`, Forward `⌘]`, Enclosing folder `⌘↑`, breadcrumb bar, Rescan `⌘R`, Scan Folder `⌘O`.

## Full Disk Access

To see protected folders (Mail, Messages, Safari, other users), grant DiskView Full Disk Access in
System Settings → Privacy & Security → Full Disk Access. The app shows a shortcut when access is missing.
The build script signs with your Apple Development certificate when the keychain has one, so the
grant survives rebuilds. Without one it falls back to ad-hoc signing, and macOS then forgets the grant
after every rebuild.

## Developer aids

- `DiskView --scan <path>` prints totals and timing without opening a window.
- `DISKVIEW_SNAPSHOT=<dir> DISKVIEW_SNAPSHOT_PATH=<path> DiskView` walks through the screens and saves PNGs.

## License

MIT. See [LICENSE](LICENSE).
