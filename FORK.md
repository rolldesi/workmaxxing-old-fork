# Workmaxxing

Workmaxxing is an unofficial fork of
[manaflow-ai/cmux](https://github.com/manaflow-ai/cmux), built for running many
coding agents side by side. It is not affiliated with or endorsed by
Manaflow, Inc. "cmux" is Manaflow's name; it appears here only where the code
and its tooling (the `cmux` CLI, settings paths) still use it.

## Modified

Modified by rolldesi, starting 2026-11-22. The changes focus on running many
coding agents side by side in one window:

- **Agent-to-agent message cap.** Two agents may exchange 10 messages before
  a person steps in. Each box shows how many it has left ("8+") in its tab
  bar; clicking adds 10. Boxes that hit the cap turn grey until raised or
  prompted.
- **Traffic lights.** Each box's border shows its agent's state: blue while
  working, red when it stopped and needs you, green when done. Clicking a box
  clears red or green. Upstream's blue unread ring and pane flash default off.
- **Enlarge a box.** Triple-click inside a terminal to grow it to about 70% of
  the window on a smooth spring; focusing another box restores the layout.
- **Box colors.** Per-box tint and outline colors from the Apps menu.
- **Apps button** in every tab bar: Spotify (Web API player with search and
  queue), sticky note, prompt queue (can feed a box when its agent is done),
  Calendar, Obsidian vault browser, markdown file, PDF.
- **Browser picker.** The globe button offers Chrome or Safari profiles seeded
  with that browser's cookies, or a plain browser.
- **Files sidebar.** An Agents | Files switch in the left sidebar with a file
  explorer and VS Code-style Open, Open Folder, Open File and Open Recent.
- **Dev builds.** `scripts/reload.sh` honours `CMUX_DEV_SIGN_IDENTITY` so
  macOS privacy grants survive rebuilds.

See the git history (`git log manaflow-ai/main..`) for the exact changes.

## License

Unchanged from upstream. The app, CLI and the code changed here are
GPL-3.0-or-later, and these modifications are released under the same terms.
The server directories listed in [LICENSE](LICENSE) remain under the Business
Source License 1.1 and are not modified by this fork. See [LICENSE](LICENSE)
and [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
