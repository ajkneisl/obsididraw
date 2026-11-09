import {
	App,
	Editor,
	FileView,
	Keymap,
	MarkdownPostProcessorContext,
	MarkdownRenderChild,
	Notice,
	PaneType,
	Platform,
	Plugin,
	PluginSettingTab,
	Setting,
	TFile,
	WorkspaceLeaf,
	loadPdfJs,
	moment,
	normalizePath,
} from "obsidian";
import { exportToPdf } from "./export";
import { DrawingDocument, EXTENSION, PAPER_PRESETS, blankDrawing, parseDrawing } from "./format";
import { PdfJsDocument, renderDrawing } from "./render";
import { saveWithPrompt } from "./save";

const VIEW_TYPE = "obsididraw-view";

interface ObsididrawSettings {
	/** Use the dark page color and invert ink in dark themes, the way PencilKit does on iPad. */
	adaptToTheme: boolean;
	/** Page size preset for drawings created from Obsidian. */
	newDrawingSize: string;
	/** What clicking an embed does: open the Obsididraw app on iPad/iPhone only, always, or never. */
	clickOpensApp: "ios" | "always" | "never";
}

const DEFAULT_SETTINGS: ObsididrawSettings = { adaptToTheme: true, newDrawingSize: "infinite", clickOpensApp: "ios" };

/** Undocumented but long-standing API used to render `![[file.ext]]` embeds for custom extensions. */
interface EmbedRegistry {
	registerExtension(ext: string, creator: (context: { containerEl: HTMLElement }, file: TFile, subpath?: string) => MarkdownRenderChild): void;
	unregisterExtension(ext: string): void;
}

export default class ObsididrawPlugin extends Plugin {
	settings: ObsididrawSettings = DEFAULT_SETTINGS;
	readonly embeds = new Set<DrawingEmbed>();

	async onload() {
		this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());

		this.registerView(VIEW_TYPE, (leaf) => new DrawingView(leaf, this));
		this.registerExtensions([EXTENSION], VIEW_TYPE);
		this.registerEmbeds();
		this.addSettingTab(new ObsididrawSettingTab(this.app, this));

		this.addCommand({
			id: "export-pdf",
			name: "Export drawing to PDF",
			checkCallback: (checking) => {
				const file = this.app.workspace.getActiveFile();
				if (file?.extension !== EXTENSION) return false;
				if (!checking) void this.exportPdf(file);
				return true;
			},
		});

		this.addCommand({
			id: "open-in-app",
			name: "Open in Obsididraw",
			checkCallback: (checking) => {
				const file = this.app.workspace.getActiveFile();
				if (file?.extension !== EXTENSION) return false;
				if (!checking) this.openInApp(file);
				return true;
			},
		});

		this.addCommand({
			id: "create-drawing-at-cursor",
			name: "Create drawing at cursor",
			icon: "pencil",
			editorCallback: (editor, ctx) => void this.createDrawingAtCursor(editor, ctx.file),
		});

		this.registerEvent(
			this.app.workspace.on("editor-menu", (menu, editor, info) => {
				menu.addItem((item) =>
					item
						.setTitle("Create drawing here")
						.setIcon("pencil")
						.onClick(() => void this.createDrawingAtCursor(editor, info.file)),
				);
			}),
		);

		this.registerEvent(
			this.app.workspace.on("file-menu", (menu, file) => {
				if (!(file instanceof TFile) || file.extension !== EXTENSION) return;
				menu.addItem((item) =>
					item
						.setTitle("Open in Obsididraw")
						.setIcon("pencil")
						.onClick(() => this.openInApp(file)),
				);
				menu.addItem((item) =>
					item
						.setTitle("Export to PDF")
						.setIcon("file-down")
						.onClick(() => void this.exportPdf(file)),
				);
			}),
		);

		this.registerEvent(
			this.app.vault.on("modify", (file) => {
				if (file instanceof TFile && file.extension === EXTENSION) this.refresh(file);
			}),
		);
		this.registerEvent(this.app.workspace.on("css-change", () => this.refresh()));
	}

	onunload() {
		this.embedRegistry()?.unregisterExtension(EXTENSION);
	}

	async saveSettings() {
		await this.saveData(this.settings);
		this.refresh();
	}

	/** Re-renders open views and embeds, optionally only those showing `file`. */
	refresh(file?: TFile) {
		for (const leaf of this.app.workspace.getLeavesOfType(VIEW_TYPE)) {
			const view = leaf.view;
			if (view instanceof DrawingView && (!file || view.file === file)) void view.render();
		}
		for (const embed of this.embeds) {
			if (!file || embed.file === file) void embed.loadFile();
		}
	}

	/** Reads, parses and renders `file` into `el`, replacing its contents. */
	async renderInto(el: HTMLElement, file: TFile) {
		try {
			const doc = parseDrawing(await this.app.vault.cachedRead(file));
			const pdfFile = this.backgroundPdf(doc, file);
			let pdf: PdfJsDocument | undefined;
			if (pdfFile) {
				const pdfjs = await loadPdfJs();
				pdf = await pdfjs.getDocument({ data: new Uint8Array(await this.app.vault.readBinary(pdfFile)) }).promise;
			}
			renderDrawing(el, doc, { dark: this.settings.adaptToTheme && document.body.hasClass("theme-dark"), pdf });
		} catch (error) {
			el.empty();
			el.createDiv({ cls: "obsididraw-error", text: `Couldn't display ${file.name}: ${(error as Error).message}` });
		}
	}

	/** Opens `file` in the Obsididraw app, which picks it up from the same vault. */
	openInApp(file: TFile) {
		const vault = encodeURIComponent(this.app.vault.getName());
		window.open(`obsididraw://open?vault=${vault}&file=${encodeURIComponent(file.path)}`);
	}

	/** Handles a click on an embed: the app on iPad/iPhone (by default), otherwise Obsidian's view. */
	openDrawing(file: TFile, newLeaf: PaneType | boolean) {
		const mode = this.settings.clickOpensApp;
		if (mode === "always" || (mode === "ios" && Platform.isIosApp)) {
			this.openInApp(file);
		} else {
			void this.app.workspace.getLeaf(newLeaf).openFile(file);
		}
	}

	/**
	 * Creates a blank drawing where Obsidian puts new attachments for this note, and embeds it
	 * at the cursor (replacing any selection).
	 */
	async createDrawingAtCursor(editor: Editor, note: TFile | null) {
		try {
			const sourcePath = note?.path ?? "";
			const name = `Drawing ${moment().format("YYYY-MM-DD HH.mm.ss")}.${EXTENSION}`;
			const path = await this.app.fileManager.getAvailablePathForAttachment(name, sourcePath);
			const file = await this.app.vault.create(path, JSON.stringify(blankDrawing(this.settings.newDrawingSize)));
			editor.replaceSelection(`!${this.app.fileManager.generateMarkdownLink(file, sourcePath)}`);
		} catch (error) {
			new Notice(`Couldn't create a drawing: ${(error as Error).message}`);
		}
	}

	/** Renders `file` to PDF and asks where to save it. */
	async exportPdf(file: TFile) {
		try {
			const doc = parseDrawing(await this.app.vault.read(file));
			const pdfFile = this.backgroundPdf(doc, file);
			const bytes = await exportToPdf(doc, pdfFile ? await this.app.vault.readBinary(pdfFile) : undefined);

			const base = pdfFile ? `${pdfFile.basename} (annotated)` : file.basename;
			const saved = await saveWithPrompt(this.app, bytes, `${base}.pdf`, file);
			if (saved?.kind === "disk") {
				new Notice(`Exported to ${saved.path}`);
			} else if (saved?.kind === "vault") {
				new Notice(`Exported ${saved.file.path}`);
				await this.app.workspace.getLeaf("tab").openFile(saved.file);
			}
		} catch (error) {
			new Notice(`Couldn't export ${file.name}: ${(error as Error).message}`);
		}
	}

	/** The PDF a drawing annotates, resolved relative to the drawing's folder. */
	private backgroundPdf(doc: DrawingDocument, file: TFile): TFile | undefined {
		if (!doc.pdf) return undefined;
		const folder = file.parent?.path ?? "";
		const segments: string[] = folder && folder !== "/" ? folder.split("/") : [];
		for (const part of doc.pdf.split("/")) {
			if (part === "..") segments.pop();
			else if (part && part !== ".") segments.push(part);
		}
		const resolved = this.app.vault.getAbstractFileByPath(normalizePath(segments.join("/")));
		if (resolved instanceof TFile) return resolved;
		throw new Error(`can't find the PDF “${doc.pdf}”.`);
	}

	private embedRegistry(): EmbedRegistry | undefined {
		const registry = (this.app as unknown as { embedRegistry?: EmbedRegistry }).embedRegistry;
		return typeof registry?.registerExtension === "function" ? registry : undefined;
	}

	private registerEmbeds() {
		const registry = this.embedRegistry();
		if (registry) {
			registry.registerExtension(EXTENSION, ({ containerEl }, file) => new DrawingEmbed(this, containerEl, file));
			return;
		}

		// Fallback for Obsidian builds without the embed registry: reading view only.
		this.registerMarkdownPostProcessor((el: HTMLElement, ctx: MarkdownPostProcessorContext) => {
			el.querySelectorAll<HTMLElement>(".internal-embed").forEach((embedEl) => {
				const src = embedEl.getAttribute("src");
				if (!src) return;
				const file = this.app.metadataCache.getFirstLinkpathDest(src.split("#")[0], ctx.sourcePath);
				if (!file || file.extension !== EXTENSION) return;
				const embed = new DrawingEmbed(this, embedEl, file);
				ctx.addChild(embed);
				void embed.loadFile();
			});
		});
	}
}

class DrawingEmbed extends MarkdownRenderChild {
	constructor(
		private plugin: ObsididrawPlugin,
		containerEl: HTMLElement,
		readonly file: TFile,
	) {
		super(containerEl);
		containerEl.addClass("obsididraw-embed");
		this.registerDomEvent(containerEl, "click", (evt) => {
			evt.preventDefault();
			plugin.openDrawing(file, Keymap.isModEvent(evt));
		});
	}

	onload() {
		this.plugin.embeds.add(this);
	}

	onunload() {
		this.plugin.embeds.delete(this);
	}

	async loadFile() {
		await this.plugin.renderInto(this.containerEl, this.file);
	}
}

class DrawingView extends FileView {
	constructor(
		leaf: WorkspaceLeaf,
		private plugin: ObsididrawPlugin,
	) {
		super(leaf);
		this.addAction("file-down", "Export to PDF", () => {
			if (this.file) void plugin.exportPdf(this.file);
		});
		this.addAction("pencil", "Open in Obsididraw", () => {
			if (this.file) plugin.openInApp(this.file);
		});
	}

	getViewType() {
		return VIEW_TYPE;
	}

	getDisplayText() {
		return this.file?.basename ?? "Obsididraw";
	}

	getIcon() {
		return "pencil";
	}

	canAcceptExtension(extension: string) {
		return extension === EXTENSION;
	}

	async onLoadFile(file: TFile) {
		this.contentEl.addClass("obsididraw-view");
		await this.render();
	}

	async onUnloadFile(file: TFile) {
		this.contentEl.empty();
	}

	async render() {
		if (this.file) await this.plugin.renderInto(this.contentEl, this.file);
	}
}

class ObsididrawSettingTab extends PluginSettingTab {
	constructor(
		app: App,
		private plugin: ObsididrawPlugin,
	) {
		super(app, plugin);
	}

	display() {
		this.containerEl.empty();
		new Setting(this.containerEl)
			.setName("Follow dark theme")
			.setDesc("In dark themes, show drawings on their dark page color with inverted ink, like PencilKit does on iPad. PDFs always stay light.")
			.addToggle((toggle) =>
				toggle.setValue(this.plugin.settings.adaptToTheme).onChange(async (value) => {
					this.plugin.settings.adaptToTheme = value;
					await this.plugin.saveSettings();
				}),
			);
		new Setting(this.containerEl)
			.setName("Clicking a drawing")
			.setDesc("What happens when you click an embedded drawing. Opening the Obsididraw app needs the app installed, with this vault open in it.")
			.addDropdown((dropdown) =>
				dropdown
					.addOption("ios", "Edit in Obsididraw on iPad and iPhone")
					.addOption("always", "Always edit in Obsididraw")
					.addOption("never", "Always view in Obsidian")
					.setValue(this.plugin.settings.clickOpensApp)
					.onChange(async (value) => {
						this.plugin.settings.clickOpensApp = value as ObsididrawSettings["clickOpensApp"];
						await this.plugin.saveSettings();
					}),
			);
		new Setting(this.containerEl)
			.setName("Page size for new drawings")
			.setDesc("Used by “Create drawing at cursor”. Change it later in the app's Page Setup.")
			.addDropdown((dropdown) => {
				for (const [key, preset] of Object.entries(PAPER_PRESETS)) dropdown.addOption(key, preset.title);
				dropdown.setValue(this.plugin.settings.newDrawingSize).onChange(async (value) => {
					this.plugin.settings.newDrawingSize = value;
					await this.plugin.saveSettings();
				});
			});
	}
}
