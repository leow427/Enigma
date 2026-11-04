# F36 weather card: design prototypes

Design prototypes for F36 in `to-do.md`. Nothing here is built into the app.

- [weather-cards.html](weather-cards.html): the first interactive mockup, with
  every option (flat or soft sky, split or full-sky card, panel or window width,
  units, Reduce Motion). Open it in a browser.
- [renders/](renders/): the SwiftUI version, drawn with the app's own palette,
  fonts and character, in Paper and Ink. Eight sample replies, every sky, and
  the character's weather costumes.
- [swift/](swift/): the SwiftUI source of those renders, kept as reference.

## Chosen direction (owner, 2026-11-03)

- **Flat sky**: solid colours, outlined shapes and two hills, like the
  character. No gradients, blur or glow.
- **Split card**: the illustrated sky holds the place, the big temperature
  and the condition; the details sit on the app's `surface`, so they follow
  Paper and Ink and stay readable.
- **The character dresses for the weather** while a weather card shows on the
  latest reply:

  | Weather | Costume |
  | --- | --- |
  | Sun (clear or partly cloudy, day or twilight) | Sunglasses over the porthole |
  | Clear night | A striped nightcap with a pompom |
  | Rain | An umbrella balanced on the antenna |
  | Thunderstorm | The umbrella blown inside out, with gusts |
  | Snow | A woolly hat (the antenna ball is its bobble) and a scarf |
  | Overcast or fog | A scarf |

## Re-rendering

The renders came from a hosted test. To make them again, copy `swift/` back
for one run, add the files to `Enigma.xcodeproj` (`WeatherCard.swift` and
`WeatherSky.swift` beside `Enigma/Chat/MapCard.swift`,
`EnigmaCharacterCostume.swift` in `Enigma/App/`, the test in `EnigmaTests/`),
then run:

```sh
scripts/verify-xcode.sh test -only-testing:EnigmaTests/WeatherCardSnapshotTests
```

The PNGs land in `/private/tmp/claude-501/EnigmaWeatherCards/`. Take the files
back out of the project afterwards.

## Open questions for the plan

- Tomorrow's hourly strip needs the hourly request extended to 48 hours (the
  forecast holds 24), or no strip for future days.
- Snow in cm needs `snowfall_sum` in the daily request; the Oslo card shows mm.
- The live character is drawn by the stage, which may need room above its
  30 pt slot for the umbrella and hats.
