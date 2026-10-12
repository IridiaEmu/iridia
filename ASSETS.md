# ASSETS

Where every piece of Iridia's own art and sound comes from. Everything here was made for this project;
nothing is downloaded, sampled or AI-generated. Third-party code and its licences are in the in-app
Acknowledgements.

## Glass cube (logo, app icon, launch screen, in-app 3D)
- **In the app:** a live SceneKit model built in code: `Source/iOS/App/Common/Swift/Branding/IridiaCube.swift`
  (chamfered cube + a custom refraction/dispersion/thin-film glass shader + a procedural studio panorama).
- **App icon and launch screen:** rendered from the same scene by `Tools/branding/render_cube.swift`
  (`--icon` for the 1024 px App Store icon; plain mode for the transparent launch image).
- **Offline path-traced version:** `Tools/branding/cube_blender.py` (Blender 5.2, Cycles), for marketing
  stills if wanted.
- History: the earlier cube images (`applogo.jpg`, `LogoIridia.jpg`, provided by the owner) were
  generated art; they were replaced by the model and removed from the app on 2026-10-12.

## Interface sounds
- Synthesised from scratch by `Tools/branding/make_sounds.swift` (sine partials with inharmonic,
  struck-glass ratios, exponential decays, a tiny noise transient). Files:
  `Source/iOS/App/Common/Resources/Sounds/iridia_{tick,press,open,close,launch,error}.wav`.
- Licence: GPL-2.0-or-later with the rest of the project (the generator is the source).

## Music
- None, by the owner's decision (2026-10-12).

## Fonts
- System fonts only for Iridia's own UI and launch screen.
