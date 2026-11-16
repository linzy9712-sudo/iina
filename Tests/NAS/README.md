# NAS / Jellyfin development and regression checks

Run `Tests/NAS/run.sh` from the repository. The harnesses compile the production
Foundation modules directly; no third-party testing dependency is needed.

Automated coverage:
- Mapping component boundaries, longest prefix, explicit priority, ambiguity,
  Unicode normalization, case policy, and traversal rejection.
- Credential-free configuration/index persistence and account/address isolation.
- Mock HTTP pagination, authenticated requests, reverse-proxy base paths,
  authentication failure and incomplete-page rejection.
- Real temporary folders plus a PlayerCore test double: recursive natural order,
  multiple roots, hidden/non-video filtering, deduplication, append without opening,
  one idle-player open, and cancellation suppressing completion.
- Invalid persisted geometry fallback and validation of new geometry preferences.

Build on macOS with initialized Xcode and the project's existing binary dependencies:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project iina.xcodeproj -scheme iina -configuration Debug \
  -derivedDataPath /tmp/iina-nas-build -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build
```

This checkout was built using the matching dylib filenames and youtube-dl from the
locally installed IINA app. Package.resolved was preserved. No dependency upgrade,
mpv/FFmpeg source change, server change, or application installation is required.

Manual acceptance still required (no real NAS credentials were supplied):
1. Settings → NAS / Jellyfin: add a server including any reverse-proxy base path,
   enter credentials and sign in. Confirm Token exists only in Keychain. Test a
   non-admin account, bad credentials, offline server, and reauthentication.
2. Refresh index. Cancel a refresh and disconnect the network mid-page: the prior
   saved snapshot must remain usable. Move/delete a server-side item, refresh,
   and verify the stale path no longer matches.
3. Add POSIX mappings (e.g. /Volumes/NAS/Movies → /media/movies), test a real file,
   duplicate the mapping at equal priority and verify ambiguity is reported.
   Test two servers/accounts with overlapping paths. A match is from the cached
   snapshot, not proof that the item is currently online/playable.
4. Play local A, then drag two folders from Finder onto the video center, OSC,
   and standalone playlist. Verify one player, natural order within each root,
   preserved A/current position/pause/window frame, and deduplication on repeat.
   Repeat from the initial window with “always open in new window” enabled.
5. Set initial geometry to 1440% in an isolated test preference domain. Startup
   must ignore the invalid geometry without an mpv error dialog. The UI must
   reject percentages above 100 while accepting 1440 points and 100%.
6. Test after a cold app restart and on macOS 12 as well as the build machine.

Implemented in the development app: authenticated playback negotiation, direct
playback and HLS transcoding, quality presets, resume and playback reports, scoped
transcode cleanup, audio/subtitle selection, live library and cached physical-folder
browsing, mapped folder import, and persistent mixed local/Jellyfin playlists.
Saved remote entries contain stable server/item identities, not playback URLs or tokens.

Additional automated coverage in `run.sh`: stable queue identities, mixed playlist
persistence, playback negotiation, quality limits, resume, cross-origin rejection,
playback reporting and transcode cleanup using a mock HTTP server.

Native libmpv verification (requires ffmpeg and a signed development app):

```sh
python3 Tests/NAS/mpv_queue_test.py build/IINA.app
```

This verifies authenticated HLS manifest/segment requests, mixed queue advancement,
and current-item preservation during moves, appends and removals.

Full application smoke test (requires a Debug build and an awake graphical macOS session):

```sh
python3 Tests/NAS/app_integration_test.py build/IINA.app
```

The full-app test uses a temporary NAS store, a synthetic Keychain credential and a
loopback server; cleanup removes that credential. It explicitly configures pause,
loop and keep-open in the fixture process via acknowledged IPC commands, without
changing user preferences.

On 2026-11-17, after waking the display, the full-app test passed: Keychain lookup,
PlaybackInfo negotiation, authenticated HLS manifest and segments, start/stop reports,
and session-scoped transcode cleanup. The earlier CVDisplayLink -6661 blocker did
not recur. Build and headless regression checks also passed. This fixture result
does not replace acceptance against a real Jellyfin server.

Additional manual acceptance:
7. Sign in, browse a library, play a video, then add local files and mapped NAS
   folders to the same queue. Reorder, remove, skip and allow automatic advancement.
8. Test Auto, Original, 1080p and 720p against the real server. Seek in HLS, switch
   audio/subtitles, stop during negotiation, then confirm transcode cleanup on server.
9. Resume a partially watched video; check progress on Jellyfin after pause/stop.
10. Save a mixed playlist, restart, restore it and confirm fresh playback negotiation.

Current limits: indexing refreshes the entire paginated snapshot, not incremental
updates. Physical browsing uses indexed server paths; it is not an independent SMB
file browser. Folder trees/favorites/recent shortcuts and direct editing of saved
playlist entries are not implemented (edit the current queue and save again).
Real-server codecs, subtitle formats, permissions and older macOS still need manual
acceptance. The browser is a separate window placed beside the player when space allows.

HTTP NAS address policy: at the user's request, the app permits HTTP to all
user-configured server addresses through NSAllowsArbitraryLoads. The local/web
fine-grained NSAllows keys and domain exceptions are intentionally absent because
they can override that setting. This is an app-wide ATS exception, not a per-server
switch. Standard HTTPS certificate trust validation and the client's credential
redirect restrictions remain in place.

Browser navigation regression (requires a graphical macOS session):

```sh
python3 Tests/NAS/browser_navigation_test.py
```

Runs the production navigation and column-rendering methods in an AppKit fixture:
back/forward, ancestor jumps, history branching, duplicate navigation prevention,
ancestor columns and switching views without changing the location. It does not
replace visual acceptance of the full application.
