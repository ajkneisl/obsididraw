import {
	BlendMode,
	PDFDocument,
	PDFOperator,
	PDFPage,
	appendBezierCurve,
	appendQuadraticCurve,
	clip,
	closePath,
	concatTransformationMatrix,
	degrees,
	endPath,
	lineTo,
	moveTo,
	popGraphicsState,
	pushGraphicsState,
	rgb,
} from "pdf-lib";
import { DrawingDocument } from "./format";
import { Matrix, Point, StrokeShape, apply, pageSize, parseColor, polygonPath, strokeShape } from "./geometry";

/**
 * Builds a PDF of the drawing: one page per page, ink as vector shapes on the light page color,
 * on top of the background PDF's pages when there is one.
 */
export async function exportToPdf(doc: DrawingDocument, backgroundPdf?: ArrayBuffer): Promise<Uint8Array> {
	const out = await PDFDocument.create();
	out.setProducer("Obsididraw");
	const source = backgroundPdf ? await PDFDocument.load(backgroundPdf, { ignoreEncryption: true }) : undefined;
	const pageColor = hexToRgb(doc.paper.color.light);

	for (const [i, page] of doc.pages.entries()) {
		const shapes = page.strokes.map(strokeShape).filter((s): s is StrokeShape => s !== null);
		const { width, height } = pageSize(doc, page, shapes);
		const pdfPage = out.addPage([width, height]);
		pdfPage.drawRectangle({ x: 0, y: 0, width, height, color: pageColor });

		if (source && i < source.getPageCount()) {
			await drawSourcePage(out, pdfPage, source.getPage(i), width, height);
		}
		for (const shape of shapes) drawShape(pdfPage, shape, height);
	}
	return out.save();
}

/** Places a background PDF page, honoring its crop box and rotation. */
async function drawSourcePage(out: PDFDocument, target: PDFPage, page: PDFPage, width: number, height: number) {
	const crop = page.getCropBox();
	const embedded = await out.embedPage(page, {
		left: crop.x,
		bottom: crop.y,
		right: crop.x + crop.width,
		top: crop.y + crop.height,
	});
	const rotation = ((page.getRotation().angle % 360) + 360) % 360;
	// Pages rotate clockwise for display; pdf-lib rotates counter-clockwise about (x, y).
	const placement: Record<number, { x: number; y: number; angle: number }> = {
		0: { x: 0, y: 0, angle: 0 },
		90: { x: 0, y: height, angle: -90 },
		180: { x: width, y: height, angle: 180 },
		270: { x: width, y: 0, angle: 90 },
	};
	const { x, y, angle } = placement[rotation] ?? placement[0];
	target.drawPage(embedded, { x, y, rotate: degrees(angle) });
}

function drawShape(page: PDFPage, shape: StrokeShape, pageHeight: number) {
	const { color } = parseColor(shape.color);
	const options = {
		x: 0,
		y: pageHeight,
		color: hexToRgb(color),
		opacity: shape.alpha,
		borderWidth: 0,
		blendMode: shape.ink === "marker" ? BlendMode.Multiply : undefined,
	};

	if (!shape.mask) {
		page.drawSvgPath(polygonPath(shape.polygon), options);
		return;
	}

	// Clip to the eraser mask. The flip turns PDF's y-up space into the drawing's y-down space,
	// and is its own inverse, so applying it again restores the space drawSvgPath expects.
	const flip = concatTransformationMatrix(1, 0, 0, -1, 0, pageHeight);
	page.pushOperators(pushGraphicsState(), flip, ...maskOperators(shape.mask.path, shape.mask.matrix), clip(), endPath(), flip);
	page.drawSvgPath(polygonPath(shape.polygon), options);
	page.pushOperators(popGraphicsState());
}

/** Converts mask path data (absolute M, L, Q, C, Z) into PDF path operators in page space. */
function maskOperators(path: string, matrix: Matrix): PDFOperator[] {
	const ops: PDFOperator[] = [];
	for (const [, command, args] of path.matchAll(/([MLQCZ])([^MLQCZ]*)/g)) {
		const n = args.trim().split(/[\s,]+/).filter(Boolean).map(Number);
		const pts: Point[] = [];
		for (let i = 0; i + 1 < n.length; i += 2) pts.push(apply(matrix, [n[i], n[i + 1]]));
		if (command === "M" && pts[0]) ops.push(moveTo(...pts[0]));
		else if (command === "L" && pts[0]) ops.push(lineTo(...pts[0]));
		else if (command === "Q" && pts[1]) ops.push(appendQuadraticCurve(...pts[0], ...pts[1]));
		else if (command === "C" && pts[2]) ops.push(appendBezierCurve(...pts[0], ...pts[1], ...pts[2]));
		else if (command === "Z") ops.push(closePath());
	}
	return ops;
}

function hexToRgb(hex: string) {
	const { color } = parseColor(hex);
	const value = parseInt(color.slice(1), 16);
	return rgb(((value >> 16) & 0xff) / 255, ((value >> 8) & 0xff) / 255, (value & 0xff) / 255);
}
