// Pure stroke geometry shared by the on-screen renderer and the PDF exporter.

import { DrawingDocument, DrawingPage, DrawingStroke, isInfinite } from "./format";

/** Curve samples per B-spline segment. */
const STEPS = 4;
/** Segments used to approximate each round end cap. */
const CAP_SEGMENTS = 8;
/** Blank space kept around the content of infinite drawings. */
export const PADDING = 16;

export type Point = [number, number];
export type Matrix = [number, number, number, number, number, number];

interface Sample {
	x: number;
	y: number;
	/** Radius (half the stroke width). */
	r: number;
	opacity: number;
}

export interface Bounds {
	minX: number;
	minY: number;
	maxX: number;
	maxY: number;
}

export interface StrokeShape {
	/** Closed outline polygon in page coordinates. */
	polygon: Point[];
	color: string;
	alpha: number;
	ink: string;
	/** Clip path in stroke coordinates, with the matrix that maps it into page coordinates. */
	mask?: { path: string; matrix: Matrix };
}

export const IDENTITY: Matrix = [1, 0, 0, 1, 0, 0];

export function strokeMatrix(stroke: DrawingStroke): Matrix {
	return stroke.transform?.length === 6 ? (stroke.transform as Matrix) : IDENTITY;
}

export function apply(m: Matrix, [x, y]: Point): Point {
	return [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]];
}

/** Converts a stroke into a filled shape in page coordinates. */
export function strokeShape(stroke: DrawingStroke): StrokeShape | null {
	const samples = sampleStroke(stroke.points);
	if (samples.length === 0) return null;
	const matrix = strokeMatrix(stroke);
	const { color, alpha } = parseColor(stroke.color);
	const opacity = samples.reduce((sum, s) => sum + s.opacity, 0) / samples.length;
	return {
		polygon: outlinePolygon(samples).map((p) => apply(matrix, p)),
		color,
		alpha: alpha * opacity,
		ink: stroke.ink,
		mask: stroke.mask ? { path: stroke.mask, matrix } : undefined,
	};
}

/**
 * PencilKit stores strokes as uniform cubic B-spline control points. Evaluate the spline
 * (clamped by repeating the end points) to get a smooth centerline with per-sample widths.
 */
function sampleStroke(points: number[][]): Sample[] {
	const controls: Sample[] = points
		.filter((p) => p.length >= 2)
		.map((p) => ({
			x: p[0],
			y: p[1],
			r: ((p[3] ?? 2) + (p[4] ?? p[3] ?? 2)) / 4,
			opacity: p[5] ?? 1,
		}));
	if (controls.length < 3) return controls;

	const first = controls[0];
	const last = controls[controls.length - 1];
	const c = [first, first, ...controls, last, last];
	const out: Sample[] = [];
	for (let i = 0; i + 3 < c.length; i++) {
		for (let s = 0; s < STEPS; s++) {
			const t = s / STEPS;
			const t2 = t * t;
			const t3 = t2 * t;
			const b0 = (1 - 3 * t + 3 * t2 - t3) / 6;
			const b1 = (4 - 6 * t2 + 3 * t3) / 6;
			const b2 = (1 + 3 * t + 3 * t2 - 3 * t3) / 6;
			const b3 = t3 / 6;
			const mix = (k: keyof Sample) => b0 * c[i][k] + b1 * c[i + 1][k] + b2 * c[i + 2][k] + b3 * c[i + 3][k];
			out.push({ x: mix("x"), y: mix("y"), r: mix("r"), opacity: mix("opacity") });
		}
	}
	out.push(last);
	return out;
}

/** Offsets the centerline by the radius on each side, joined by round caps. */
function outlinePolygon(samples: Sample[]): Point[] {
	const arc = (cx: number, cy: number, r: number, from: number, segments: number): Point[] =>
		Array.from({ length: segments + 1 }, (_, k) => {
			const a = from - (Math.PI * k) / segments;
			return [cx + Math.cos(a) * r, cy + Math.sin(a) * r];
		});

	if (samples.length === 1) {
		const { x, y, r } = samples[0];
		return arc(x, y, r, 0, CAP_SEGMENTS * 2).slice(0, -1).concat(arc(x, y, r, Math.PI, CAP_SEGMENTS * 2).slice(0, -1));
	}

	const normals: Point[] = [];
	let nx = 0;
	let ny = 1;
	for (let i = 0; i < samples.length; i++) {
		const prev = samples[Math.max(i - 1, 0)];
		const next = samples[Math.min(i + 1, samples.length - 1)];
		const dx = next.x - prev.x;
		const dy = next.y - prev.y;
		const len = Math.hypot(dx, dy);
		if (len > 1e-6) {
			nx = -dy / len;
			ny = dx / len;
		}
		normals.push([nx, ny]);
	}

	const left = samples.map(({ x, y, r }, i): Point => [x + normals[i][0] * r, y + normals[i][1] * r]);
	const right = samples.map(({ x, y, r }, i): Point => [x - normals[i][0] * r, y - normals[i][1] * r]);
	const end = samples[samples.length - 1];
	const start = samples[0];
	const endAngle = Math.atan2(normals[normals.length - 1][1], normals[normals.length - 1][0]);
	const startAngle = Math.atan2(normals[0][1], normals[0][0]) + Math.PI;

	return [
		...left,
		...arc(end.x, end.y, end.r, endAngle, CAP_SEGMENTS).slice(1, -1),
		...right.reverse(),
		...arc(start.x, start.y, start.r, startAngle, CAP_SEGMENTS).slice(1, -1),
	];
}

export function polygonPath(polygon: Point[]): string {
	return polygon.map(([x, y], i) => `${i === 0 ? "M" : "L"}${fmt(x)} ${fmt(y)}`).join("") + "Z";
}

export function shapeBounds(shapes: StrokeShape[]): Bounds | null {
	if (shapes.length === 0) return null;
	const b: Bounds = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
	for (const shape of shapes) {
		for (const [x, y] of shape.polygon) {
			b.minX = Math.min(b.minX, x);
			b.minY = Math.min(b.minY, y);
			b.maxX = Math.max(b.maxX, x);
			b.maxY = Math.max(b.maxY, y);
		}
	}
	return b;
}

/** The page's size; infinite pages end just below their lowest stroke. */
export function pageSize(doc: DrawingDocument, page: DrawingPage, shapes: StrokeShape[]): { width: number; height: number } {
	if (!isInfinite(doc)) return { width: page.width, height: page.height };
	const bounds = shapeBounds(shapes);
	return { width: page.width, height: Math.max((bounds?.maxY ?? 0) + PADDING * 2, page.width / 4) };
}

export function parseColor(hex: string): { color: string; alpha: number } {
	const match = /^#?([0-9a-f]{6})([0-9a-f]{2})?$/i.exec(hex ?? "");
	if (!match) return { color: "#000000", alpha: 1 };
	return { color: `#${match[1]}`, alpha: match[2] ? parseInt(match[2], 16) / 255 : 1 };
}

export function fmt(n: number): string {
	return (Math.round(n * 100) / 100).toString();
}
