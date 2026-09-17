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
