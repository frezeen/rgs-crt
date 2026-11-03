# Changelog

## 2026-11-04

- **Taito Type X2: King of Fighters Maximum Impact Regulation A now draws its intro on the tube.** The title runs direct on the 640x480i raster (`gamescope` off for this game alone), which is what lets the runner's patched ddraw put its CRI Sofdec intro — a DirectDraw YUY2 overlay — on the real screen instead of on a nested swapchain: on the glass the intro comes up and the frame keeps being presented. The title still closes by itself after about half a minute inside a Wine OpenGL thread fault, so it is not certified: `docs/emulators-status.md` keeps it OPEN.

## 2026-11-03

- **Profile picker: two pictures instead of two buttons.** The launch-time profile chooser now shows the arcade cabinet for the 15 kHz CRT profile and a flat-panel TV for the LCD one, each with its name and description ("4:3 CRT 15 kHz", "modern LCD/TV 16:9 high definition"), and a large up-arrow under the selected panel as the selection indicator. The artwork is transparent and composites on the picker's black raster, so the tube shows the cabinet and the TV and nothing else; the unselected picture steps back, dimmed.
- **Sega RingEdge: certified 100% on 15 kHz CRT.** The full Sega RingEdge and RingEdge 2 arcade roster is now certified on the tube. High-definition 16:9 widescreen canvas titles scale edge-to-edge onto the 4:3 glass without letterboxing (**Sega RingEdge: Initial D Arcade Stage 6/7/8**, **Sega RingEdge: Guilty Gear Xrd -SIGN-**, **Sega RingEdge: Guilty Gear Xrd Revelator / Rev2**, **Sega RingEdge: Under Night In-Birth Exe:Late**, **Sega RingEdge: Blade Strangers**, etc.); native 4:3 titles with baked 16:9 pillar bezels (**Sega RingEdge: Guilty Gear XX Accent Core Plus R**, **Sega RingEdge: Melty Blood Actress Again Current Code RE2**) crop directly to authentic 4:3 full-bleed on CRT via D3D9 source rect in Windows Arcade Loader userprofiles with zero GPU overhead.
- **RGS 43.76 system compatibility.** Layer certified and fully aligned against live RGS 43.76 system update, ensuring display services, launch hooks, and update notifications operate reliably.
- **EmulationStation on-screen update notifications for RGS base system and CRT layer.** Enhanced update checks to distinguish and notify users via on-screen message box when a newer base RGS system update or combined update is available, with background throttling to prevent duplicate prompts during a session.
- **Session cleanup and lazy overlay unmount.** Enhanced launch and deploy scripts to automatically clean up squashfs overlay and Wine mount points upon game termination, preventing device-busy collisions.

## 2026-11-02

- **Sega RingWide: certified 100% on 15 kHz CRT.** The full Sega RingWide / RingEdge arcade roster is now certified on the tube. Direct D3D9 backbuffer scaling fills the 4:3 glass without letterboxing for SD and screen-windowed titles (**Sega RingWide: Dream Raiders**, **Sega RingWide: Chaos Code**, **Sega RingWide: Let's Go Safari**) at 0.8% GPU overhead; Gamescope cleanly downscales XGA titles (**Sega RingWide: Medaru no Gunman**, **Sega RingWide: Melty Blood Actress Again Current Code** from 1024x768 to 640x480) and Full HD 16:9 titles (**Sega RingWide: Sonic & Sega All-Stars Racing** from 1920x1080 to 864x486 stretch pixel); and class-level loader pinning guarantees Windows Arcade Loader execution across all titles.
- **KonamiPC: certified 100% on 15 kHz CRT.** The full Konami PC arcade roster is now certified on the tube, scaling high-definition and standard arcade titles to 640x480i via gamescope downscaling with dedicated per-game canvases (1920x1080 for **KonamiPC: Road Fighters 3D**, 1360x768 for **KonamiPC: GTI Club**, 1024x768 for **KonamiPC: HyperSports**, and direct 640x480 for **KonamiPC: Silent Hill**).
- **Universal configuration cleanup on crash.** Session configuration overrides are now tracked with dirty crash protection across all emulators, ensuring temporary files are cleanly removed at exit and never falsely retained as stock files.

## 2026-11-01

- **KonamiPC: GTI Club Supermini Festa launches.** The XACT 2.10 engine class was left pointing at a dump path that disappears on unmount, producing a dead COM path and a crash at startup. The engine class is now restored to the loader's stable built-in per launch.
- **KonamiPC: researched per-game canvas block for the 15 kHz CRT.** All 29 titles now carry explicit canvases (native 640x480 4:3 direct where correct, exact per-title canvases like GTI Club 1360x768 and Cooper's 9 1280x512, HD 16:9 on the shared 720p canvas) filling the tube without distortion.
- **Lindbergh: host network no longer frozen by the title's AM OS.** After Burner Climax reconfigures the NIC onto an arcade subnet; the host interface is now shielded so NFS-mounted roms remain reachable and the box no longer locks up.

## 2026-10-31

- **ArcadePC: Sega Rally 2 25th Anniversary [4-3] runs on the solo 15 kHz CRT.** Its D3D layer dereferences NULL when its device is created with the LCD disabled (page fault in MGameD3D.dll); hosting the title under a 4:3 gamescope canvas (1280x960 → 640x480) with authored dgVoodoo (FullScreenMode=true, ScalingMode=stretched) gives it its own output so the disabled CRT never reaches the game — full-frame 4:3 picture, no letterbox.
- **ArcadePC: Senninha GP runs on the solo 15 kHz CRT.** The stock wine-tkg runner ships a 4 KB ddraw.dll stub with no exports, so DirectDrawCreateEx is unimplemented and the title dies at startup; running it under the wine-9.17 runner (full 32-bit ddraw) with the same 4:3 gamescope canvas restores the picture with the LCD off.
- **Cleaner teardown on game launch.** Orphaned Windows processes and stale wine mount points are now cleared at gameStart, preventing locked loop devices and hangs when re-launching a title.

## 2026-10-29

- **ArcadePC: Family Guy Bowling Arcade canvas adaptation.** Configured high-definition 16:9 widescreen canvas adaptation scaled cleanly to 640x480 on 15kHz CRT monitors.
- **ArcadePC: Friction widescreen rendering.** High-definition 16:9 arcade canvas configured to scale edge-to-edge onto the 4:3 15kHz tube.
- **ArcadePC: Pop Moto direct 3D startup sequence.** Configured custom 3D rasterizer startup commands and canvas scaling to launch smoothly and fill the 15kHz CRT display.
- **ArcadePC: The House of the Dead III high-resolution raster scaling.** High-resolution 1280x1024 PC rendering scaled cleanly to native 640x480i CRT raster, preserving smooth arcade frame pacing without downscaling artifacts.
- **Clean emulator exit and resource release on Windows arcade games.** Background helper daemons and temporary wine filesystem mounts are now automatically unmounted and terminated upon game exit, preventing locked loop devices and ensuring smooth transitions back to EmulationStation without hangs.
