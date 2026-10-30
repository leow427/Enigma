# Article fixtures

Original text written for Enigma's tests; nothing here is copied from a real
site. Names, places and figures are invented.

| File | Used by | What it is |
| --- | --- | --- |
| `article-news.html` | `testExtractsNewsArticle` | A news article with `og:site_name`, `article:published_time`, JSON-LD, navigation, an advert, comments and a footer. |
| `article-docs.html` | `testDocsPageKeepsHeadingsAndCode` | A documentation page with headings, code blocks, a table and a list, in a known order. |
| `script-only.html` | `testScriptOnlyPageIsNotReaderable` | An app shell: an empty root `div`, scripts and a `<noscript>` notice. |
| `subresources.html` | `testNoSubresourceLoads` | Every load vector CP0 tried, pointing at `{{ORIGIN}}`, which the test replaces with a local listener. |
| `meta-refresh.html` | `testMetaRefreshDoesNotNavigate` | A short article whose meta refresh points at `{{ORIGIN}}/moved`. |
