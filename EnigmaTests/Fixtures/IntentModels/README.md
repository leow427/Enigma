# Intent model fixtures

These are test fixtures, not the app's models. `search/train.jsonl` (70
examples) and `think/train.jsonl` (60) hold invented examples, and the models
beside them were trained from them by the script, from the repository root:

```sh
scripts/train-intent-models.sh --data EnigmaTests/Fixtures/IntentModels --out EnigmaTests/Fixtures/IntentModels --kind maxEnt search
scripts/train-intent-models.sh --data EnigmaTests/Fixtures/IntentModels --out EnigmaTests/Fixtures/IntentModels --kind bert think
```

`IntentSearch.mlmodel` is a maximum-entropy model, and `IntentThink.mlmodel` a
BERT one. The search examples include years, so `IntentModelsTests` can check
that the app feeds the model year words, and its cut-off isn't 0.5.

The models aren't added to any target. `IntentModelsTests` compiles them at run
time, reads their metadata, and checks their answers. The app's models live in
`Enigma/Resources/IntentModels/` and are trained from `IntentTraining/`.
