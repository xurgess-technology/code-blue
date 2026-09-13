# Third-party code

Libraries shipped with the project (art and sound licences are in [ASSETS.md](ASSETS.md)).

## GodotSteam GDExtension 4.22.1

- What: Steamworks bindings for Godot 4.4+, including `SteamMultiplayerPeer`. Used by
  `scripts/net.gd` for Steam lobbies, invites and peer-to-peer play. Optional at runtime: the
  game falls back to ENet when the extension or the Steam client is missing.
- Where: `addons/godotsteam/` (64-bit Windows, Linux and macOS libraries only; the Android,
  32-bit and ARM builds in the release were left out, and so was the optional editor updater
  plug-in).
- Source: the official GodotSteam release `v4.22.1-gde`,
  `godotsteam-4.22.1-gdextension-plugin-4.4.zip`, from
  <https://codeberg.org/godotsteam/godotsteam/releases/tag/v4.22.1-gde> (GodotSteam's releases
  moved from GitHub to Codeberg; the GitHub repository only carries overflow files now).
- Licence: MIT, copyright (c) 2015-current GP Garcia, Chris Ridenour and contributors. Full
  text in `addons/godotsteam/license.md`.
- Includes Valve's Steamworks SDK 1.65 redistributables (`steam_api64.dll`, `libsteam_api.so`,
  `libsteam_api.dylib`), redistributed under the Steamworks SDK Access Agreement.
- `steam_appid.txt` holds 480 (Valve's public "Spacewar" test app) for development. A real
  release needs its own app id there and in `Net.STEAM_APP_ID`.
