// Pure stroke geometry shared by the on-screen renderer and the PDF exporter.

import { DrawingDocument, DrawingPage, DrawingStroke, isInfinite } from "./format";

/** Target distance between curve samples, in points, and the most samples per spline segment. */
const SAMPLE_SPACING = 0.25;
const MAX_STEPS = 32;
/** How far a simplified outline may stray from the true curve, in points. */
const TOLERANCE = 0.02;
const MAX_RADIUS_DRIFT = 0.04;
const MAX_RUN = 32;
/** Radius floor, so ink written while zoomed in still shows up as a line. */
const MIN_RADIUS = 0.2;
/**
 * A point's stored size isn't the width PencilKit draws. The solid width to draw instead is
 * scale × (size − offset). See docs/FORMAT.md. Unlisted inks render like `pen`.
 */
const INK_WIDTH: Record<string, { scale: number; offset: number }> = {
	pen: { scale: 2, offset: 2 },
	monoline: { scale: 2, offset: 2 },
	fountainPen: { scale: 1, offset: 2 },
	pencil: { scale: 1, offset: 0 },
	crayon: { scale: 1, offset: 0 },
	watercolor: { scale: 1, offset: 0 },
	marker: { scale: 1, offset: 0 },
};
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
	/** Closed, consistently wound polygons in page coordinates, to fill together with a nonzero rule. */
	polygons: Point[][];
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
	const samples = sampleStroke(stroke.points, INK_WIDTH[stroke.ink] ?? INK_WIDTH.pen);
	if (samples.length === 0) return null;
	const matrix = strokeMatrix(stroke);
	const { color, alpha } = parseColor(stroke.color);
	const opacity = samples.reduce((sum, s) => sum + s.opacity, 0) / samples.length;
	return {
		polygons: strokePolygons(samples).map((polygon) => polygon.map((p) => apply(matrix, p))),
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
function sampleStroke(points: number[][], ink: { scale: number; offset: number }): Sample[] {
	const controls: Sample[] = points
		.filter((p) => p.length >= 2)
		.map((p) => ({
			x: p[0],
			y: p[1],
			r: Math.max((ink.scale * (((p[3] ?? 2) + (p[4] ?? p[3] ?? 2)) / 2 - ink.offset)) / 2, MIN_RADIUS),
			opacity: p[5] ?? 1,
		}));
	if (controls.length < 3) return controls;

	const first = controls[0];
	const last = controls[controls.length - 1];
	const c = [first, first, ...controls, last, last];
	const out: Sample[] = [];
	for (let i = 0; i + 3 < c.length; i++) {
		const span = Math.hypot(c[i + 2].x - c[i + 1].x, c[i + 2].y - c[i + 1].y);
		const steps = Math.min(Math.max(Math.ceil(span / SAMPLE_SPACING), 2), MAX_STEPS);
		for (let s = 0; s < steps; s++) {
			const t = s / steps;
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

/** Drops samples that a straight chord and constant width would reproduce within TOLERANCE. */
function simplify(samples: Sample[]): Sample[] {
	if (samples.length < 3) return samples;
	const kept = [samples[0]];
	let run = 0;
	let turn = 0;
	for (let i = 1; i < samples.length - 1; i++) {
		const [a, s, next] = [samples[i - 1], samples[i], samples[i + 1]];
		const [ux, uy, vx, vy] = [s.x - a.x, s.y - a.y, next.x - s.x, next.y - s.y];
		run += Math.hypot(ux, uy);
		turn += Math.abs(Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy));
		// A run of length L turning by T strays from its chord by about L·T/8.
		if (run * turn > TOLERANCE * 8 || run > MAX_RUN || Math.abs(s.r - kept[kept.length - 1].r) > MAX_RADIUS_DRIFT) {
			kept.push(s);
			run = 0;
			turn = 0;
		}
	}
	kept.push(samples[samples.length - 1]);
	return kept;
}

/** A circle, wound the same way as the quads in `strokePolygons`. */
function disk({ x, y, r }: Sample): Point[] {
	const segments = Math.min(Math.max(Math.ceil(Math.PI * Math.sqrt(r / (2 * TOLERANCE))), 8), 64);
	return Array.from({ length: segments }, (_, k): Point => {
		const a = (-2 * Math.PI * k) / segments;
		return [x + Math.cos(a) * r, y + Math.sin(a) * r];
	});
}

/**
 * The stroke as a union of disks at each sample and a quad between each pair. All pieces wind the
 * same way, so a nonzero fill merges them. A single offset outline can't do this: on curves tighter
 * than the pen is wide it folds over itself and leaves holes.
 */
function strokePolygons(samples: Sample[]): Point[][] {
	const kept = simplify(samples);
	const polygons = [disk(kept[0])];
	for (let i = 1; i < kept.length; i++) {
		const [a, b] = [kept[i - 1], kept[i]];
		const len = Math.hypot(b.x - a.x, b.y - a.y);
		if (len > 1e-6) {
			const [nx, ny] = [-(b.y - a.y) / len, (b.x - a.x) / len];
			polygons.push([
				[a.x + nx * a.r, a.y + ny * a.r],
				[b.x + nx * b.r, b.y + ny * b.r],
				[b.x - nx * b.r, b.y - ny * b.r],
				[a.x - nx * a.r, a.y - ny * a.r],
			]);
		}
		polygons.push(disk(b));
	}
	return polygons;
}

export function polygonsPath(polygons: Point[][]): string {
	return polygons.map((polygon) => polygon.map(([x, y], i) => `${i === 0 ? "M" : "L"}${fmt(x)} ${fmt(y)}`).join("") + "Z").join("");
}

export function shapeBounds(shapes: StrokeShape[]): Bounds | null {
	if (shapes.length === 0) return null;
	const b: Bounds = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
	for (const shape of shapes) {
		for (const [x, y] of shape.polygons.flat()) {
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
