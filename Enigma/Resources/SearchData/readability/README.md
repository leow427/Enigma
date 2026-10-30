# Readability for page reading

Mozilla's Readability.js, bundled unmodified for F29's article extraction
(`Enigma/Search/ArticleExtractor.swift`, spec §4). It runs only inside the
sealed `WKWebView`, in the isolated `EnigmaExtract` content world.

- **Source:** https://github.com/mozilla/readability
- **Version:** tag `0.6.0`, commit `04fd32f72b448c12b02ba6c40928b67e510bac49`
- **Licence:** Apache-2.0 (`LICENSE.md`; the notice is also in
  `Enigma/Resources/ThirdPartyNotices.txt`)

| File | SHA-256 | From |
| --- | --- | --- |
| `Readability.js` | `34dcab3d0832d0019f02990eed6b6124e029e8c32b9f0c6f2550544ff8dff174` | the tag |
| `Readability-readerable.js` | `a98d28805804c1986ceed470678a3f409f150ee7f1d227f8c8239c005d21de65` | the tag |
| `LICENSE.md` | `a5b1e8181751ce05b85b7bfaa832b785e87086250a5148e679d17ca9bdcfa958` | the tag |
| `EnigmaExtract.js` | not pinned | Enigma's own |

To check the copies: `shasum -a 256 Readability.js Readability-readerable.js LICENSE.md`
here, and compare with the same files at the tag
(`https://raw.githubusercontent.com/mozilla/readability/0.6.0/<file>`).
`ArticleExtractorTests.testBundledReadabilityMatchesPinnedHashes` checks
the bundled files against this table.

To update: download the three files from the new tag, replace them, update
this table and the version in `ThirdPartyNotices.txt`, and run
`ArticleExtractorTests`.

The folder sits outside the lists' 3 MB budget (decision D61): the budget
check counts only `SearchData`'s top-level files.
