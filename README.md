# Obsididraw

Handwritten notes for Obsidian. Obsididraw is an iPad app (it also runs on Mac) that draws with
Apple Pencil straight into an Obsidian vault, and an Obsidian plugin that shows those drawings
in your notes.

Drawings are saved as `.draw` files: plain JSON holding every stroke, with no private binary
alongside. The format is described in [docs/FORMAT.md](docs/FORMAT.md).

## The app

- Open a vault folder, then browse, create, rename and delete drawings and folders in it.
- Draw with the PencilKit tools, plus lines, arrows, rectangles, ellipses and triangles.
- Choose infinite paper or pages (A4, A5, US Letter, US Legal or a custom size), a page color
  for light and dark appearance, and a template such as lined, squares, dots or Cornell notes.
- Add pages, and delete them again.
- Annotate a PDF from the vault. The ink goes in a companion `Name.pdf.draw` file, so the PDF
  itself is never changed.
- Export a drawing as a PDF, or jump to it in Obsidian.

## The Obsidian plugin

The plugin in [obsidian-plugin](obsidian-plugin) displays `.draw` files in Obsidian, embeds them
in notes with `![[My Drawing.draw]]`, exports them to PDF, and opens them in the app. See its
[README](obsidian-plugin/README.md) for everything it does and how to install it.

## Building

The app needs Xcode 27 and targets iPadOS 27. Open `Obsididraw.xcodeproj` and run the
`Obsididraw` scheme on an iPad or an iPad simulator.

The plugin builds with Node:

```sh
cd obsidian-plugin
npm install
npm run build
```

## License

[MIT](LICENSE)
