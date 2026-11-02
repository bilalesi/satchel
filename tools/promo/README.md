# Promo video tooling

Records the demo app (`scripts/demo.sh`, fake data only) with a real pointer and assembles the promo with ffmpeg.
Nothing here is part of the app.

1. `./build.sh` once (helpers, icons). Needs `ffmpeg`, Python with Pillow, Screen Recording and Accessibility
   permission for the terminal that runs it.
2. `./reset.sh` starts a fresh demo, unlocked on "Personal", the window at its full size (not macOS full screen).
   Update scene: `EXTRA_ENV="SATCHEL_UPDATE_FEED=http://127.0.0.1:8765/feed.json" ./reset.sh`.
3. `./take.sh NAME SECONDS SCENE.sh` records the screen rectangle of the window while the scene drives it
   (`tourA`, `syncB`, `updateD`, `customC`, `quickE`, `iconsG`; `selectiveF` needs `DEMO_SYNC=1 ./reset.sh`).
4. `python3 cards.py && python3 design.py render` draws the promo on the GPU (`render.swift`: sub-pixel camera,
   transitions, captions, magnifiers, 60 fps) from the shot list in `design.py` and writes `satchel-promo-v2.mp4`.
   (`build_video.py` is the first, ffmpeg-only cut.)

Safety: `ui` only clicks, types or scrolls while the demo is the front app (it brings the demo back first and
logs every time in `steal.log`); a take with a non-empty log should be thrown away. The update scene never
installs anything: install would replace the demo with the release build, which ignores the isolation switch.
