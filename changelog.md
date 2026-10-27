# Changelog

## 2026-10-27

- **NESiCAxLive: Space Invaders authentic 3:4 vertical arcade display with dedicated side bezels.** Configured authentic 3:4 playfield proportions on 4:3 15kHz CRT monitors, filling the symmetrical 114-pixel side pillar margins with dedicated arcade cabinet bezels via native daemonized overlay without Gamescope downscaling or input latency.
- **NESiCAxLive: SD resolution direct rendering and crash fixes.** Resolved startup crashes and eliminated letterboxing across native SD titles: **NESiCAxLive: Exception** runs direct native 4:3 (640x480i) bypassing the 720p crash; **NESiCAxLive: Tottemo E Mahjong** boots directly into 640x480i fixing the stock 1280x800 template crash; **NESiCAxLive: Trouble Witches AC Episode 1** runs native 640x480i direct; and **NESiCAxLive: Yatagarasu - Attack on Cataclysm** runs direct borderless at 640x480i with 16:9 side banners cropped cleanly.
- **ArcadePC: Bug Busters full-screen 4:3 direct launch with video decoding.** Configured direct 640x480i full-screen playback on 15kHz CRT with DirectShow MPEG-1 video decoding re-enabled under Wine, allowing the game's animated intro and title sequence to play smoothly without stalling.
- **ArcadePC: Bullseye / Crack Shot authentic lightgun arcade bezels.** Added dedicated 16:9 arcade cabinet side bezels for **ArcadePC: Bullseye** and **ArcadePC: Crack Shot**, preserving authentic CRT arcade artwork without artificial flat-panel distortion.
- **Taito Type X: 3D Cosplay Mahjong CRT profile mapping.** Added userprofile configuration for 15kHz CRT tube display to ensure correct 640x480i raster mapping and launch stability.
- **RGS 43.75 and 43.72 system compatibility.** Layer certified and fully aligned against live RGS 43.72 and 43.75 updates, ensuring display services, launch hooks, and update feed checks operate reliably across upgrades.
- **Display service and diagnostic logging consolidation.** Standardized VNC remote access and diagnostic tools to record logs in `/userdata/system/logs/vnc.log`, keeping system logging uniform.
- **EmulationStation on-screen update notifications.** The boot service now asynchronously checks for remote updates once EmulationStation and networking are active, displaying a modal message box directly inside EmulationStation when an RGS-CRT layer update is available, or advising the user when a newer base RGS system update must be installed first.


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

## 2026-10-21

- **Interlaced HDMI and TV panel compatibility.** Fixed boot crashes on TVs and monitors advertising 1080i modes over HDMI by properly sanitizing display boundary definitions.
- **Dual display widescreen LCD scaling.** The display engine now strictly selects progressive modes over interlaced modes on digital panels, enabling hardware scaling to stretch the cloned 4:3 arcade desktop edge-to-edge on 16:9 LCDs without black borders.
- **Seamless updater verification.** Verification now accounts for pre-reboot state during installs and updates on AMD/Intel systems, eliminating false failure banners in the EmulationStation update tool.
- **NESiCAxLive arcade library certified on CRT.** Full 50-game library tuned for the 4:3 tube, with native raster on horizontal classics and authentic 3:4 orientation with arcade bezels on vertical shooters.
  - **Widescreen HD arcade titles stretch cleanly to fill the tube.** Modern
    16:9 widescreen releases (BlazBlue, Persona 4 Arena, Under Night In-Birth,
    Ultra Street Fighter IV, Crimzon Clover, Yatagarasu, etc.) utilize targeted
    Gamescope canvas scaling to fill the entire 4:3 tube edge to edge without black bars.
- **Multi-system configuration scoping.** Profiles now support declaring custom
  configuration files independently across different systems, ensuring that game-specific
  overrides for one emulator (such as MAME or Windows arcade games) are only applied
  when launching games on that specific system.
- **Safe game termination on system updates.** When applying configuration updates,
  active Windows arcade games and background emulator processes are cleanly closed,
  preventing launch collisions and leaving EmulationStation responsive.

## 2026-10-21 — Sega Chihiro arcade games certified on the tube; RGS upgrade scripts protected

- **Sega Chihiro arcade games certified on the tube.** Chihiro titles fill the 4:3
  tube edge to edge at native 640x480 resolution on an interlaced 60 Hz signal,
  with authentic arcade proportions and zero extra sharpening or cosmetic shaders.
- **Reliable graphics rendering via Vulkan API.** Chihiro now utilizes the native Vulkan
  graphics backend on AMD GPUs, resolving graphics ring timeouts and crashes that occurred
  under OpenGL and ensuring smooth, stable gameplay with low GPU overhead (34%). Verified
  across multiple titles (Crazy Taxi High Roller, OutRun 2 Special Tours, The House of the Dead III).
- **RGS utility update scripts run without interruption.** The display supervisor now
  prioritizes RGS utility menu scripts over orphan checks, ensuring that system upgrade scripts
  that restart the menu are never prematurely aborted.
- **Robust process clean-up on game exit.** The process tree killer safely guards against
  terminating inherited session process groups when the frontend closes, keeping background
  display services and remote access active.

## 2026-10-20 — Sega Model 2 certified on the tube; game launches protected from false timeouts

- **Sega Model 2 arcade games certified on the tube (Daytona USA).** Titles
  fill the 4:3 tube edge to edge at the native arcade refresh rate (57.52 Hz) on
  an interlaced signal, locked with zero tearing and smooth frame pacing.
  Internal 3D rendering runs at native 1:1 resolution instead of the heavy 4x
  supersampling shipped by stock, keeping graphics faithful to the original arcade
  board while keeping GPU load minimal (19%).
- **Authentic arcade rendering on the tube.** Sega Model 2 games use the arcade
  monitor's own continuous beam scaling, original draw distance, and authentic
  stipple transparency. Software CRT cosmetic filters designed for flat screens
  are disabled on the real tube.
- **Game launches are protected from false timeouts.** The system supervisor
  now evaluates game windows relative to the active screen mode, ensuring that
  low-resolution, vertical arcade, and interlaced titles are recognized immediately
  and never killed during startup.
- **Games returning to the menu release the screen cleanly.** If an arcade game
  or Windows title exits or hangs, the background manager terminates all child
  processes and safely brings back the main menu without freezing the display.

