import { DrawingDocument, isInfinite } from "./format";
import { TEMPLATE_OPACITY, templatePath } from "./template";
import { PADDING, StrokeShape, fmt, pageSize, parseColor, polygonsPath, shapeBounds, strokeShape } from "./geometry";

const SVG_NS = "http://www.w3.org/2000/svg";

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

	const observer = options.pdf
		? new IntersectionObserver((entries) => {
				for (const entry of entries) {
					if (!entry.isIntersecting) continue;
					observer?.unobserve(entry.target);
					const index = Number((entry.target as HTMLElement).dataset.page);
					void renderPdfPage(options.pdf!, index, entry.target as HTMLElement);
				}
			}, { rootMargin: "200px" })
		: undefined;

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
		pageEl.style.maxWidth = `${Math.ceil(viewBox[2])}px`;

		if (options.pdf && i < options.pdf.numPages) {
			const pdfEl = pageEl.createDiv({ cls: "obsididraw-pdf-page" });
			pdfEl.dataset.page = String(i + 1);
			observer?.observe(pdfEl);
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

async function renderPdfPage(pdf: PdfJsDocument, pageNumber: number, el: HTMLElement) {
	const page = await pdf.getPage(pageNumber);
	const base = page.getViewport({ scale: 1 });
	// Render at the element's on-screen size, so text stays sharp.
	const scale = Math.max(el.clientWidth / base.width, 1) * (window.devicePixelRatio || 1);
	const viewport = page.getViewport({ scale });
	const canvas = el.createEl("canvas");
	canvas.width = Math.ceil(viewport.width);
	canvas.height = Math.ceil(viewport.height);
	const ctx = canvas.getContext("2d");
	if (ctx) await page.render({ canvasContext: ctx, viewport }).promise;
}

function svgEl<K extends keyof SVGElementTagNameMap>(tag: K, attrs: Record<string, string>): SVGElementTagNameMap[K] {
	const el = document.createElementNS(SVG_NS, tag);
	for (const [key, value] of Object.entries(attrs)) el.setAttribute(key, value);
	return el;
}
