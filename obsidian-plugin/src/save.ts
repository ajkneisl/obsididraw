import { App, FileSystemAdapter, FuzzySuggestModal, Platform, TFile, TFolder, normalizePath } from "obsidian";

/** Where an export ended up: a file on disk outside Obsidian's view, or a file in the vault. */
export type SavedLocation = { kind: "disk"; path: string } | { kind: "vault"; file: TFile };

interface ElectronDialog {
	showSaveDialog(options: {
		title: string;
		defaultPath: string;
		filters: { name: string; extensions: string[] }[];
	}): Promise<{ canceled: boolean; filePath?: string }>;
}

/**
 * Asks where to save, like Obsidian's own "Export to PDF": the system save dialog on desktop,
 * or a vault folder picker on mobile. Returns null if the user cancels.
 */
export async function saveWithPrompt(app: App, data: Uint8Array, fileName: string, near: TFile): Promise<SavedLocation | null> {
	const dialog = desktopSaveDialog();
	if (dialog) {
		const adapter = app.vault.adapter;
		const folder = near.parent?.path ?? "/";
		const defaultDir = adapter instanceof FileSystemAdapter ? adapter.getFullPath(folder === "/" ? "" : folder) : "";
		const nodePath = window.require("path") as typeof import("path");
		const result = await dialog.showSaveDialog({
			title: "Export to PDF",
			defaultPath: nodePath.join(defaultDir, fileName),
			filters: [{ name: "PDF", extensions: ["pdf"] }],
		});
		if (result.canceled || !result.filePath) return null;
		const fs = window.require("fs") as typeof import("fs");
		await fs.promises.writeFile(result.filePath, data);
		return { kind: "disk", path: result.filePath };
	}

	const folder = await new FolderPicker(app, near.parent).choose();
	if (!folder) return null;
	const base = fileName.replace(/\.pdf$/i, "");
	const prefix = folder.isRoot() ? "" : `${folder.path}/`;
	let path = normalizePath(`${prefix}${base}.pdf`);
	for (let n = 1; app.vault.getAbstractFileByPath(path); n++) {
		path = normalizePath(`${prefix}${base} ${n}.pdf`);
	}
	const buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
	return { kind: "vault", file: await app.vault.createBinary(path, buffer) };
}

function desktopSaveDialog(): ElectronDialog | undefined {
	if (!Platform.isDesktopApp) return undefined;
	try {
		const electron = window.require("electron") as { remote?: { dialog?: ElectronDialog } };
		return electron.remote?.dialog;
	} catch {
		return undefined;
	}
}

declare global {
	interface Window {
		require: NodeJS.Require;
	}
}

/** Lets the user pick a vault folder, listing the drawing's own folder first. */
class FolderPicker extends FuzzySuggestModal<TFolder> {
	private resolve?: (folder: TFolder | null) => void;
	private chosen = false;

	constructor(
		app: App,
		private preferred: TFolder | null,
	) {
		super(app);
		this.setPlaceholder("Choose a folder to save the PDF in");
	}

	choose(): Promise<TFolder | null> {
		return new Promise((resolve) => {
			this.resolve = resolve;
			this.open();
		});
	}

	getItems(): TFolder[] {
		const folders = this.app.vault.getAllFolders(true);
		const preferred = this.preferred;
		return preferred ? [preferred, ...folders.filter((f) => f !== preferred)] : folders;
	}

	getItemText(folder: TFolder): string {
		return folder.isRoot() ? "/" : folder.path;
	}

	onChooseItem(folder: TFolder) {
		this.chosen = true;
		this.resolve?.(folder);
	}

	onClose() {
		super.onClose();
		// Obsidian calls onClose before onChooseItem, so wait a tick before treating it as a cancel.
		window.setTimeout(() => {
			if (!this.chosen) this.resolve?.(null);
		}, 0);
	}
}
