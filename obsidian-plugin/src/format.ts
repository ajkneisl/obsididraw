// Types and parsing for the .draw format. See docs/FORMAT.md in the repository.

export const EXTENSION = "draw";
export const SUPPORTED_VERSION = 1;

export interface DrawingStroke {
	ink: string;
	color: string;
	transform?: number[];
	mask?: string;
	seed?: number;
	created?: number;
	/** [x, y, t, w, h, opacity, force, azimuth, altitude, secondaryScale] */
	points: number[][];
}

export interface DrawingPage {
	width: number;
	height: number;
	strokes: DrawingStroke[];
}

export interface Paper {
	size: string;
	width: number;
	height: number;
	color: { light: string; dark: string };
	/** The pattern behind the ink: see template.ts. Missing means blank; ignored on PDFs. */
	template?: string;
}

export interface DrawingDocument {
	type: "obsididraw";
	version: number;
	source?: string;
	paper: Paper;
	/** Path of the background PDF, relative to the drawing's folder. */
	pdf?: string;
	pages: DrawingPage[];
}

const DEFAULT_PAPER: Paper = {
	size: "infinite",
	width: 800,
	height: 0,
	color: { light: "#ffffffff", dark: "#1c1c1eff" },
};

export function parseDrawing(text: string): DrawingDocument {
	const doc = JSON.parse(text) as Partial<DrawingDocument>;
	if (doc.type !== "obsididraw") throw new Error("Not an Obsididraw drawing.");
	if (typeof doc.version !== "number" || doc.version > SUPPORTED_VERSION) {
		throw new Error(`Drawing format version ${doc.version} needs a newer version of the Obsididraw plugin.`);
	}
	if (!Array.isArray(doc.pages)) throw new Error("Drawing has no pages.");
	return {
		type: "obsididraw",
		version: doc.version,
		source: doc.source,
		paper: { ...DEFAULT_PAPER, ...doc.paper, color: { ...DEFAULT_PAPER.color, ...doc.paper?.color } },
		pdf: doc.pdf,
		pages: doc.pages.map((page) => ({
			width: page.width,
			height: page.height,
			strokes: (page.strokes ?? []).filter((s) => Array.isArray(s?.points) && s.points.length > 0),
		})),
	};
}

export function isInfinite(doc: DrawingDocument): boolean {
	return doc.paper.size === "infinite";
}

/** Page presets for new drawings, in points. Matches the app's sizes. */
export const PAPER_PRESETS: Record<string, { title: string; width: number; height: number }> = {
	infinite: { title: "Infinite", width: 800, height: 0 },
	a4: { title: "A4", width: 595.28, height: 841.89 },
	a5: { title: "A5", width: 419.53, height: 595.28 },
	letter: { title: "US Letter", width: 612, height: 792 },
	legal: { title: "US Legal", width: 612, height: 1008 },
};

/** A new, empty drawing with one page of the given preset size. */
export function blankDrawing(size: string): DrawingDocument {
	const preset = PAPER_PRESETS[size] ?? PAPER_PRESETS.infinite;
	const paperSize = PAPER_PRESETS[size] ? size : "infinite";
	return {
		type: "obsididraw",
		version: SUPPORTED_VERSION,
		source: "Obsididraw for Obsidian",
		paper: { ...DEFAULT_PAPER, size: paperSize, width: preset.width, height: preset.height },
		pages: [{ width: preset.width, height: preset.height, strokes: [] }],
	};
}
