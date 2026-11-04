# F36: animated weather card (plan)

Task: `to-do.md` → F36. Design: `docs/design/f36-weather-card/README.md` (flat sky,
split card, weather costumes).

## Open questions, settled

- **Tomorrow's hourly strip.** No request change is needed: the forecast asks for
  `forecast_days=7` with no `forecast_hours`, so Open-Meteo already returns all
  168 hours (the 24 is only what `WeatherLookup.report` passes to the model). A
  future single day's strip shows that day's 06:00 to 21:00 in 3-hour steps, as
  in the Oslo render; today's shows the next 6 hours.
- **Snow in cm.** Add `snowfall_sum` to the daily request (cm, or inches with
  `precipitation_unit=inch`). A snowy day reads "Snow 70% · 6 cm".
- **F32 warm-up.** `get_weather` gains optional `start_date` and `end_date`
  (`YYYY-MM-DD`). The definition stays static (today's date is already in the
  search instructions it's offered with), and the warm-up builds its tools with
  the same `nativeToolbox` as the turn, so the warmed prefix still matches.
  `NativeToolRequestTests` already compares the warm-up's tools with the turn's.
- **Room above the slot.** The stage draws on one canvas over the whole window,
  not clipped to the 30 pt slot, so the umbrella and hats draw above it.

## Shape

1. `WeatherLookup.swift`: `is_day` (current, hourly) and `snowfall_sum` (daily),
   decoded as optional so older responses still decode.
2. `WeatherLookup.swift`: `WeatherDays` (today, tomorrow, weekend, week, a
   weekday, or the tool's dates; parsed from the question's time words) and
   `WeatherCardModel` built from `WeatherForecast`. `WeatherCard.swift` (new,
   beside `MapCard.swift`): the view. `WeatherSky.swift` (new): the lifted flat sky. The sky's timeline pauses
   off screen, with the window hidden and under Reduce Motion.
3. `EnigmaCharacterCostume.swift` (new, in `Enigma/App/`): the lifted costumes.
   The controller gets a `costume`; the stage draws it with the live frame and
   the stage's time (still under Reduce Motion). Owner addition (2026-11-03):
   putting a costume on, changing it, or taking it off is a puff of smoke round
   the body and a little hop, with the outfit swapping inside the smoke
   (`EnigmaCharacterModel.changeOutfit`); under Reduce Motion it just changes.
4. `get_weather(place?, start_date?, end_date?)` hands the card to the chat as
   soon as the forecast arrives and tells the model the card shows the numbers.
   The wording route takes the days from the question (`WebSearchRequest.weatherDays`)
   and puts the card on the weather result.
5. `ChatMessage.weatherCards` (session-only). The view model attaches cards at
   once (or with the reply's first words when the reply isn't in the chat yet),
   one per place. `EnigmaReplyView` draws them above the text;
   `AppShellView` dresses the character while the latest reply has one.

## Tests

`WeatherCardTests`: the card model (day, night, twilight, rain, snow, storm;
today, tomorrow, weekend, week, past the forecast), time words, `get_weather`
with and without the range, the wording route, the chat (card before the text,
one per place, none on failure, none after reopening), Reduce Motion, costumes.
