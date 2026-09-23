<img width="56" height="56" alt="AppIconDark" src="https://github.com/user-attachments/assets/2433910a-eab6-4762-8fcb-62193135a755" /> 

## GlucoBar

A tiny macOS menu bar app that shows your glucose reading. I made it because I got tired of digging through apps to check my blood sugar.

## What is it?

It sits in your menu bar and shows your current glucose + a little trend arrow. That's literally it.

## Features

- Shows glucose in your menu bar
- Color indicator (green = in range, red = low, orange = high or old data)
- Graph of your readings with a 3h / 6h / 12h / 24h window, hover to scrub
- Forecast for the next 15–60 minutes that blends trend, momentum, the sensor arrow, matches against your own history, a regression trained on that history and your typical-day drift, and learns which to trust by scoring itself against what actually happens (an estimate, not medical advice)
- Calibrated, asymmetric uncertainty band around the forecast, and optional notifications when a low or high is predicted
- Forecast accuracy table in Settings, plus a one-click backtest that replays your stored history
- Rolling average line and a "typical day" band built from up to 90 days of history
- Trends: time in range, average, variability and GMI for today, 7, 14, 30 or 90 days
- Works with LibreLink Up or Nightscout
- Can display mg/dL or mmol/L
- Stores your login safely in Keychain

Enjoy!

## Everyday controls

Settings is organised into Connection, Appearance, Alerts, Advanced and Data. Appearance and alert preferences save immediately; account changes take effect when you choose **Connect**. Accounts with multiple LibreLinkUp connections require an explicit person selection.

- **History** opens a separate, resizable window with date navigation, 3–72 hour zoom, comparisons with the preceding period, and a dedicated typical-day chart.
- **Privacy mode** hides readings in the menu bar and app windows and removes glucose values from new notifications. Menu-bar delta, reading age and compact spacing are optional.
- Unknown trends display `?`. Nightscout’s rapid rise and fall retain their double arrows. Graphs leave gaps when readings are more than 10 minutes apart.
- Connections refresh after wake and network recovery. Failed requests retry with increasing delays; the menu shows connection problems separately from delayed sensor readings.
- Alerts include predicted low/high and optional missing-data notifications. Settings shows macOS permission, a test button, snooze and repeat cooldowns. Snooze and cooldowns survive app restarts. Alerts require the app to run and the Mac to be awake; macOS notification settings can suppress delivery.

## Local data

Credentials live in Keychain. Glucose history is saved locally in five-minute bins under `Application Support/GlucoBar/Profiles`, separately for each LibreLinkUp account/person or Nightscout site. Forecast learning is also separate per profile. Retention is configurable from 30 to 90 days.

The Data tab exports CSV with UTC timestamps and both mg/dL and mmol/L columns. It can delete the active profile’s history and learning, or forget saved credentials. New readings are collected again after deleting history; forgetting credentials disconnects the app and retains history.

History from older versions has no recorded account/person identity. It stays unassigned until you explicitly import it into a selected profile, export it, or delete it. It is never automatically mixed with new profile history.

Advanced settings show mean forecast error and the number of checks at each horizon, plus detected crossings, missed crossings, false warnings and mean warning lead time. Crossing counts describe overlapping forecast windows beginning in range, not independent events or actual notification deliveries; windows with missing data are excluded. These are estimates and retrospective measurements, not clinical validation.

## Build and test

Open `GlucoBar.xcodeproj` in Xcode, or run:

```sh
xcodebuild -project GlucoBar.xcodeproj -scheme GlucoBar -configuration Debug -destination 'platform=macOS' test
```

`GlucoBarTests` is a hostless test bundle: it uses temporary stores and mocked network responses, without launching the app or accessing saved credentials. Coverage includes profile isolation, person selection, authentication recovery, missing-data handling, timestamp parsing, units, exports, period boundaries, persistent cooldowns and forecast evaluation.

For visual development, Debug builds accept `--demo` to use in-memory sample readings without loading account credentials or starting network polling. Release builds always use the normal connection flow.
