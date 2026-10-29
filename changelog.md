# Changelog

## 2026-10-29

- **ArcadePC: Family Guy Bowling Arcade canvas adaptation.** Configured high-definition 16:9 widescreen canvas adaptation scaled cleanly to 640x480 on 15kHz CRT monitors.
- **ArcadePC: Friction widescreen rendering.** High-definition 16:9 arcade canvas configured to scale edge-to-edge onto the 4:3 15kHz tube.
- **ArcadePC: Pop Moto direct 3D startup sequence.** Configured custom 3D rasterizer startup commands and canvas scaling to launch smoothly and fill the 15kHz CRT display.
- **ArcadePC: The House of the Dead III high-resolution raster scaling.** High-resolution 1280x1024 PC rendering scaled cleanly to native 640x480i CRT raster, preserving smooth arcade frame pacing without downscaling artifacts.
- **Clean emulator exit and resource release on Windows arcade games.** Background helper daemons and temporary wine filesystem mounts are now automatically unmounted and terminated upon game exit, preventing locked loop devices and ensuring smooth transitions back to EmulationStation without hangs.

## 2026-10-27

- **NESiCAxLive: Space Invaders authentic 3:4 vertical arcade display with dedicated side bezels.** Configured authentic 3:4 playfield proportions on 4:3 15kHz CRT monitors, filling the symmetrical 114-pixel side pillar margins with dedicated arcade cabinet bezels via native daemonized overlay without Gamescope downscaling or input latency.
- **NESiCAxLive: SD resolution direct rendering and crash fixes.** Resolved startup crashes and eliminated letterboxing across native SD titles: **NESiCAxLive: Exception** runs direct native 4:3 (640x480i) bypassing the 720p crash; **NESiCAxLive: Tottemo E Mahjong** boots directly into 640x480i fixing the stock 1280x800 template crash; **NESiCAxLive: Trouble Witches AC Episode 1** runs native 640x480i direct; and **NESiCAxLive: Yatagarasu - Attack on Cataclysm** runs direct borderless at 640x480i with 16:9 side banners cropped cleanly.
- **ArcadePC: Bug Busters full-screen 4:3 direct launch with video decoding.** Configured direct 640x480i full-screen playback on 15kHz CRT with DirectShow MPEG-1 video decoding re-enabled under Wine, allowing the game's animated intro and title sequence to play smoothly without stalling.
- **ArcadePC: Bullseye / Crack Shot authentic lightgun arcade bezels.** Added dedicated 16:9 arcade cabinet side bezels for **ArcadePC: Bullseye** and **ArcadePC: Crack Shot**, preserving authentic CRT arcade artwork without artificial flat-panel distortion.
- **Taito Type X: 3D Cosplay Mahjong authentic 3:4 vertical arcade display with dedicated side bezels.** Configured 1:1 direct 3:4 raster rendering on 640x480i CRT without horizontal squishing or Gamescope lag, framing the 140-pixel side borders with the game's authentic Japanese calligraphy and character artwork.
- **RGS 43.75 and 43.72 system compatibility.** Layer certified and fully aligned against live RGS 43.72 and 43.75 updates, ensuring display services, launch hooks, and update feed checks operate reliably across upgrades.
- **Display service and diagnostic logging consolidation.** Standardized VNC remote access and diagnostic tools to record logs in `/userdata/system/logs/vnc.log`, keeping system logging uniform.
- **EmulationStation on-screen update notifications.** The boot service now asynchronously checks for remote updates once EmulationStation and networking are active, displaying a modal message box directly inside EmulationStation when an RGS-CRT layer update is available, or advising the user when a newer base RGS system update must be installed first.
- **Deploy and session unmount resilience.** The deployment sync script now automatically clears and lazy-unmounts any active squashfs overlay mounts if an emulator session is terminated mid-game, preventing busy device collisions on the next game launch.

## 2026-10-25

- **Ballistics arcade 3D starts in native full-screen.** Removed the widescreen translation canvas and redundant game keys for Ballistics, letting it boot directly into its native full-screen 4:3 640x480 resolution without getting stuck before video mode negotiation.
- **Bounty Hunter authentic 3:4 vertical arcade display.** Corrected ReShade preset and aspect ratio mapping for Bounty Hunter: disabled artificial flat-panel bezels, virtual CRT curvature and bloom shaders, restoring clean pillarbox black borders and authentic 3:4 TATE arcade geometry on 4:3 CRT monitors.
- **Arcade PC widescreen gamescope classification.** Cleaned up native 4:3 titles from the 16:9 Gamescope forced list, reserving hardware canvas scaling strictly for actual widescreen titles.
- **Robust session termination and updater reliability.** Polling guards and update feed probes now handle active wine sessions cleanly, preventing false game timeouts and loop detections.

## 2026-10-22

- **Dreamcast keeps its 4:3 shape.** Dreamcast games now declare the picture
  as 4:3 in the emulator's aspect setting instead of following the emulator's
  internal widescreen-shaped picture, so the arcade proportions stay fixed.
- **NESiCAxLive games lose the smoothing blur.** Namco NESiCAxLive titles now
  render raw native pixels on the tube instead of the software smoothing
  filter the emulator layered over the picture.
