# Obsididraw for Obsidian

Displays and exports `.draw` drawings made with the Obsididraw app for iPad and Mac:

- Opening a drawing in Obsidian shows it as a full view, page by page.
- **Create drawing at cursor** (command palette, or right-click in a note → *Create drawing
  here*) creates a blank `Drawing <date>.draw` where Obsidian puts new attachments for that note,
  and embeds it at the cursor. Its page size comes from the plugin setting **Page size for new
  drawings**. Draw in it with the Obsididraw app.
- `![[My Drawing.draw]]` embeds it in a note, in both Live Preview and Reading view.
- Clicking an embed on iPad or iPhone opens it in the Obsididraw app to draw in (the app needs
  this vault open). Elsewhere it opens the drawing view in Obsidian. The **Clicking a drawing**
  setting can make clicks always open the app (for example the Mac app) or always stay in
  Obsidian. The drawing view's pencil button and the **Edit drawing in Obsididraw** command
  open the app too.
- Annotated PDFs (`Paper.pdf.draw`) show the PDF pages with the ink on top, using Obsidian's
  built-in PDF renderer.
- **Export to PDF** is available from the drawing view's header, the file menu, and the command
  palette. Like Obsidian's own export, it asks where to save: the system save dialog on desktop
  (starting in the drawing's folder), or a vault folder picker on mobile, after which the PDF
  opens. Ink is exported as vector shapes on the light page color.
- Views and embeds refresh when the file changes, for example after a sync from the iPad.
- Setting **Follow dark theme**: in dark themes, drawings use their dark page color and their
  ink is inverted, the way PencilKit does on iPad. PDFs always stay light.

## Build

```sh
npm install
npm run build   # typecheck, then bundle into main.js
npm run dev     # rebuild on every change
```

## Install manually

Copy `main.js`, `manifest.json` and `styles.css` into
`<vault>/.obsidian/plugins/obsididraw/`, then turn on **Obsididraw** under
Settings → Community plugins.
