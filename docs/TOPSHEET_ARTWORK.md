# Topsheet artwork operator guide

`SkiPairView` displays the user's and friends' selected skis and the equipment
picker preview. Category dimensions use `skis_catalog.waist_width_mm`; the
topsheet image supplies appearance, not ski performance. A catalog row's
`topsheet_asset_key` resolves against
`PowderMeet/Resources/SkisTopsheets.xcassets`. Without a usable asset, the
view shows the bundled PowderMeet house ski and keeps the model label.

Use only images whose redistribution in this repository is permitted. Source
files stay outside Git until their rights and appearance are reviewed. Name
each PNG `<brand-slug>-<model-slug>.png`, for example
`atomic-bent-110.png`; the importer matches those slugs to `skis_catalog`.
Processed topsheets are transparent sRGB PNGs, 1280×200 pixels.

Run commands from the repository root. A working directory such as
`~/topsheet-source/` keeps downloads and intermediate files out of Git.

## Prepare images

The simplest path is to place reviewed PNGs in
`~/topsheet-source/processed/`. If licensed source images need processing,
`tools/scrape_topsheets.py` reads operator-curated URLs from
`tools/topsheet_urls.tsv`:

```sh
python3 -m venv ~/topsheet-source/.venv
~/topsheet-source/.venv/bin/pip install requests pillow rembg onnxruntime
~/topsheet-source/.venv/bin/python tools/scrape_topsheets.py --from-urls
```

For a product page that the URL tool cannot read,
`tools/playwright_topsheets.py` can inspect an operator-reviewed page. Its
`--auto` mode searches for candidates; every downloaded image still requires
licensing and visual review before import.

```sh
~/topsheet-source/.venv/bin/pip install playwright playwright-stealth
~/topsheet-source/.venv/bin/playwright install chromium
~/topsheet-source/.venv/bin/python tools/playwright_topsheets.py --auto
```

Both tools write processed PNGs under `~/topsheet-source/processed/` and skip
existing processed slugs by default. Review each result for the correct model,
orientation, transparency, and rights before continuing.

## Import and review

```sh
~/topsheet-source/.venv/bin/pip install Pillow
~/topsheet-source/.venv/bin/python tools/import_topsheets.py ~/topsheet-source/processed
```

The importer normalizes images to 1280×200, writes one asset-catalog image set
per accepted file, and generates `tools/topsheet_keys.sql`. Review its matched
brand/model updates and commit the catalog change through a versioned migration;
do not assume `supabase db push` applies an ad hoc SQL file. The column was
introduced by
`supabase/migrations/20260509025138_skis_catalog_topsheet_keys.sql`.
Build the iOS target and inspect the picker and friend rows after importing.
