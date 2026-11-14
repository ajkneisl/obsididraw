import { DrawingDocument, isInfinite } from "./format";
import { TEMPLATE_OPACITY, templatePath } from "./template";
import { PADDING, StrokeShape, fmt, pageSize, parseColor, polygonsPath, shapeBounds, strokeShape } from "./geometry";

const SVG_NS = "http://www.w3.org/2000/svg";
/** PDF canvases stop at this many pixels, which keeps deep zooms within what browsers allow. */
const MAX_CANVAS_PIXELS = 16_000_000;

export interface RenderOptions {
	/** Use the dark page color and invert ink, as PencilKit does in dark mode. */
	dark: boolean;
	/** The background PDF, loaded with Obsidian's bundled pdf.js. */
	pdf?: PdfJsDocument;
}

/** The parts of pdf.js's document proxy we use. */
export interface PdfJsDocument {
	numPages: number;
	getPage(n: number): Promise<{
		getViewport(params: { scale: number }): { width: number; height: number };
		render(params: { canvasContext: CanvasRenderingContext2D; viewport: unknown }): { promise: Promise<void> };
	}>;
}

let clipCounter = 0;

/** Renders every page of a drawing into `container`, replacing its contents. */
export function renderDrawing(container: HTMLElement, doc: DrawingDocument, options: RenderOptions) {
	container.empty();
	const pages = container.createDiv({ cls: "obsididraw-pages" });
	// PDFs are made for light pages, so they never switch to dark.
	const dark = options.dark && !doc.pdf;
	const { color: pageColor } = parseColor(dark ? doc.paper.color.dark : doc.paper.color.light);

	const pdfPages = options.pdf ? new PdfPages(options.pdf) : undefined;

	doc.pages.forEach((page, i) => {
		const shapes = page.strokes.map(strokeShape).filter((s): s is StrokeShape => s !== null);
		const pageEl = pages.createDiv({ cls: "obsididraw-page" });
		pageEl.style.backgroundColor = pageColor;

		let viewBox: [number, number, number, number];
		if (isInfinite(doc)) {
			// Crop infinite drawings to their content.
			const b = shapeBounds(shapes);
			viewBox = b
				? [b.minX - PADDING, b.minY - PADDING, b.maxX - b.minX + PADDING * 2, b.maxY - b.minY + PADDING * 2]
				: [0, 0, page.width, page.width / 4];
			pageEl.addClass("is-infinite");
		} else {
			const size = pageSize(doc, page, shapes);
			viewBox = [0, 0, size.width, size.height];
		}
		pageEl.style.aspectRatio = `${viewBox[2]} / ${viewBox[3]}`;
		// The widest the page gets before zooming: see styles.css.
		pageEl.style.setProperty("--obsididraw-page-width", `${Math.ceil(viewBox[2])}px`);

		if (options.pdf && i < options.pdf.numPages) {
			const pdfEl = pageEl.createDiv({ cls: "obsididraw-pdf-page" });
			pdfEl.dataset.page = String(i + 1);
			pdfPages?.add(pdfEl);
		}

		// Separate from the ink, which is inverted as a whole in dark themes.
		const pattern = doc.pdf ? "" : templatePath(doc.paper.template, page.width, viewBox[1] + viewBox[3], isInfinite(doc));
		if (pattern) {
			const templateSvg = document.createElementNS(SVG_NS, "svg");
			templateSvg.addClass("obsididraw-template");
			templateSvg.setAttribute("viewBox", viewBox.map(fmt).join(" "));
			templateSvg.setAttribute("preserveAspectRatio", "xMidYMid meet");
			templateSvg.appendChild(svgEl("path", { d: pattern, fill: dark ? "#ffffff" : "#000000", "fill-opacity": String(TEMPLATE_OPACITY) }));
			pageEl.appendChild(templateSvg);
		}

		const svg = document.createElementNS(SVG_NS, "svg");
		svg.addClass("obsididraw-ink");
		svg.toggleClass("is-inverted", dark);
		svg.setAttribute("viewBox", viewBox.map(fmt).join(" "));
		svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
		svg.setAttribute("shape-rendering", "geometricPrecision");
		const defs = svg.appendChild(svgEl("defs", {}));
		for (const shape of shapes) svg.appendChild(renderShape(shape, defs));
		pageEl.appendChild(svg);
	});
}

function renderShape(shape: StrokeShape, defs: SVGDefsElement): SVGPathElement {
	const path = svgEl("path", {
		d: polygonsPath(shape.polygons),
		fill: shape.color,
		"fill-opacity": fmt(shape.alpha),
	});
	if (shape.ink === "marker") path.style.mixBlendMode = "multiply";

	if (shape.mask) {
		const id = `obsididraw-clip-${++clipCounter}`;
		const clip = svgEl("clipPath", { id, clipPathUnits: "userSpaceOnUse" });
		clip.appendChild(svgEl("path", { d: shape.mask.path, transform: `matrix(${shape.mask.matrix.map(fmt).join(" ")})` }));
		defs.appendChild(clip);
		path.setAttribute("clip-path", `url(#${id})`);
	}
	return path;
}

/**
 * Draws background PDF pages once they scroll into view, and again once they've been zoomed well
 * past the resolution they were drawn at.
 */
class PdfPages {
	private readonly visible = new Set<HTMLElement>();
	/** The scale each page was last drawn at, or is being drawn at. */
	private readonly scales = new WeakMap<HTMLElement, number>();
	private timer = 0;

	private readonly intersections = new IntersectionObserver(
		(entries) => {
			for (const entry of entries) {
				const el = entry.target as HTMLElement;
				if (entry.isIntersecting) {
					this.visible.add(el);
					void this.draw(el);
				} else {
					this.visible.delete(el);
				}
			}
		},
		{ rootMargin: "200px" },
	);

	/** Pages change size with the zoom; wait for it to settle before drawing them again. */
	private readonly resizes = new ResizeObserver(() => {
		window.clearTimeout(this.timer);
		this.timer = window.setTimeout(() => this.visible.forEach((el) => void this.draw(el)), 150);
	});

	constructor(private readonly pdf: PdfJsDocument) {}

	add(el: HTMLElement) {
		this.intersections.observe(el);
		this.resizes.observe(el);
	}

	private async draw(el: HTMLElement) {
		if (!el.isConnected) {
			this.visible.delete(el);
			return;
		}
		const page = await this.pdf.getPage(Number(el.dataset.page));
		const base = page.getViewport({ scale: 1 });
		// Draw at the element's on-screen size, so text stays sharp.
		const wanted = Math.max(el.clientWidth / base.width, 1) * (window.devicePixelRatio || 1);
		const scale = Math.min(wanted, Math.sqrt(MAX_CANVAS_PIXELS / (base.width * base.height)));
		if (scale <= (this.scales.get(el) ?? 0) * 1.2) return;
		this.scales.set(el, scale);

		const viewport = page.getViewport({ scale });
		const canvas = createEl("canvas");
		canvas.width = Math.ceil(viewport.width);
		canvas.height = Math.ceil(viewport.height);
		const ctx = canvas.getContext("2d");
		if (ctx) await page.render({ canvasContext: ctx, viewport }).promise;
		// Unless a sharper drawing was started meanwhile, which then takes the page over instead.
		if (this.scales.get(el) === scale) el.replaceChildren(canvas);
	}
}

function svgEl<K extends keyof SVGElementTagNameMap>(tag: K, attrs: Record<string, string>): SVGElementTagNameMap[K] {
	const el = document.createElementNS(SVG_NS, tag);
	for (const [key, value] of Object.entries(attrs)) el.setAttribute(key, value);
	return el;
}
