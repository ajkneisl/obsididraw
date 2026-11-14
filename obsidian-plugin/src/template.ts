// The patterns printed on pages, behind the ink. Mirrors the app's PageTemplate.swift; the
// geometry is specified in docs/FORMAT.md.

import { fmt } from "./geometry";

const SPACING = 24;
const TOP = 48;
const MARGIN = 24;
const GUTTER = 24;
const THICKNESS = 0.6;
const DOT_RADIUS = 0.9;

/** Black on light pages and white on dark ones, at this opacity. */
export const TEMPLATE_OPACITY = 0.3;

/** Values from `from` up to `end`, stepping by `step`. Includes `end` only if `through` is set. */
function steps(from: number, end: number, step: number, through = false): number[] {
	const out: number[] = [];
	for (let v = from; through ? v <= end : v < end; v += step) out.push(v);
	return out;
}

/**
 * SVG path data for a template, to fill as one shape, or "" for none. A `continuous` page has no
 * bottom edge of its own (infinite paper), so its pattern runs right to `height`.
 */
export function templatePath(template: string | undefined, width: number, height: number, continuous: boolean): string {
	const parts: string[] = [];
	const lastRule = continuous ? height : height - SPACING;
	// Compact templates fit a second rule between each pair.
	const ruleSpacing = template?.endsWith("Compact") ? SPACING / 2 : SPACING;

	const rect = (x: number, y: number, w: number, h: number) =>
		parts.push(`M${fmt(x)} ${fmt(y)}L${fmt(x + w)} ${fmt(y)}L${fmt(x + w)} ${fmt(y + h)}L${fmt(x)} ${fmt(y + h)}Z`);
	const rule = (x0: number, x1: number, y: number) => rect(x0, y - THICKNESS / 2, x1 - x0, THICKNESS);
	const divider = (x: number, y0: number, y1: number) => rect(x - THICKNESS / 2, y0, THICKNESS, y1 - y0);
	const rules = (x0: number, x1: number, bottom: number) => steps(TOP, bottom, ruleSpacing, true).forEach((y) => rule(x0, x1, y));
	const panes = (count: number) => {
		const columnWidth = (width - MARGIN * 2 - GUTTER * (count - 1)) / count;
		if (columnWidth <= 0) return;
		for (let i = 0; i < count; i++) {
			const x = MARGIN + i * (columnWidth + GUTTER);
			rules(x, x + columnWidth, lastRule);
			if (i < count - 1) divider(x + columnWidth + GUTTER / 2, MARGIN, lastRule);
		}
	};

	switch (template) {
		case "lined":
		case "linedCompact":
			rules(0, width, lastRule);
			break;
		case "squares":
			steps(SPACING, width, SPACING).forEach((x) => divider(x, 0, height));
			steps(SPACING, height, SPACING).forEach((y) => rule(0, width, y));
			break;
		case "dots": {
			const r = DOT_RADIUS;
			for (const y of steps(SPACING, height, SPACING)) {
				for (const x of steps(SPACING, width, SPACING)) {
					parts.push(`M${fmt(x - r)} ${fmt(y)}A${r} ${r} 0 1 0 ${fmt(x + r)} ${fmt(y)}A${r} ${r} 0 1 0 ${fmt(x - r)} ${fmt(y)}Z`);
				}
			}
			break;
		}
		case "cornell": {
			const cue = Math.round(width * 0.3);
			const summary = continuous ? height : Math.round(height * 0.8);
			rule(0, width, TOP);
			divider(cue, TOP, summary);
			steps(TOP + SPACING, summary, SPACING).forEach((y) => rule(cue, width, y));
			if (!continuous) rule(0, width, summary);
			break;
		}
		case "twoPaneLined":
		case "twoPaneLinedCompact":
			panes(2);
			break;
		case "threePaneLined":
		case "threePaneLinedCompact":
			panes(3);
			break;
	}
	return parts.join("");
}
