// Zooming for the drawing view: pinch on touch screens and trackpads, Ctrl/Cmd + scroll, and
// the view's zoom buttons. Pages size themselves from the --obsididraw-zoom variable in
// styles.css; ink and templates are vector, so they stay sharp at any zoom.

import { Component } from "obsidian";

/** 1 is the size the drawing opens at: the pane's width, or the page's own if that's smaller. */
const MIN_ZOOM = 1;
const MAX_ZOOM = 8;
/** How much each press of a zoom button changes the zoom. */
const STEP = 1.25;
/** The most one wheel event may zoom, so a mouse wheel notch is a step and not a leap. */
const MAX_WHEEL_DELTA = 25;
/** Wheel events this close together, in milliseconds, belong to one zoom gesture. */
const WHEEL_GESTURE_GAP = 300;

/**
 * A spot on a page, as fractions of its size. Zooming holds one in place for a whole gesture:
 * taking a new one at every step would let the rounding of scroll positions add up, and would lose
 * the spot while a page is still narrower than the view and can't be scrolled sideways.
 */
interface Anchor {
	page: HTMLElement;
	fx: number;
	fy: number;
}

interface Pinch {
	/** Distance between the two fingers, and the point midway between them. */
	distance: number;
	x: number;
	y: number;
}

export class PageZoom {
	private zoom = 1;
	private pinch: (Pinch & { anchor: Anchor | null }) | null = null;
	private wheel: { x: number; y: number; time: number; anchor: Anchor | null } | null = null;

	/** `scroller` is the scrolling element that holds the pages; `owner` unregisters the events. */
	constructor(
		private readonly scroller: HTMLElement,
		owner: Component,
	) {
		owner.registerDomEvent(scroller, "wheel", (evt) => this.onWheel(evt), { passive: false });
		owner.registerDomEvent(scroller, "touchstart", (evt) => this.onTouchesChanged(evt), { passive: true });
		owner.registerDomEvent(scroller, "touchend", (evt) => this.onTouchesChanged(evt), { passive: true });
		owner.registerDomEvent(scroller, "touchcancel", (evt) => this.onTouchesChanged(evt), { passive: true });
		owner.registerDomEvent(scroller, "touchmove", (evt) => this.onTouchMove(evt), { passive: false });
	}

	/** Zooms in (1) or out (-1) by one step, around the middle of the view. */
	step(direction: 1 | -1) {
		this.zoomAroundCenter(this.zoom * STEP ** direction);
	}

	reset() {
		this.zoomAroundCenter(1);
	}

	private zoomAroundCenter(zoom: number) {
		const box = this.scroller.getBoundingClientRect();
		const [x, y] = [box.left + box.width / 2, box.top + box.height / 2];
		this.apply(zoom, this.anchorAt(x, y), x, y);
	}

	/** The spot on the pages under a point of the viewport. */
	private anchorAt(x: number, y: number): Anchor | null {
		// Pages scale but the gaps between them don't, so a spot belongs to one page.
		const pages = Array.from(this.scroller.querySelectorAll<HTMLElement>(".obsididraw-page"));
		const page = pages.find((el) => el.getBoundingClientRect().bottom >= y) ?? pages[pages.length - 1];
		const box = page?.getBoundingClientRect();
		if (!box?.width || !box.height) return null;
		return { page, fx: (x - box.left) / box.width, fy: (y - box.top) / box.height };
	}

	/** Zooms to `zoom`, then scrolls `anchor` under a point of the viewport, as far as it'll go. */
	private apply(zoom: number, anchor: Anchor | null, x: number, y: number) {
		this.zoom = Math.min(Math.max(zoom, MIN_ZOOM), MAX_ZOOM);
		this.scroller.style.setProperty("--obsididraw-zoom", String(this.zoom));
		// The pages are replaced when the file changes, which can happen mid-gesture.
		if (!anchor?.page.isConnected) return;
		const box = anchor.page.getBoundingClientRect();
		this.scroller.scrollLeft += box.left + anchor.fx * box.width - x;
		this.scroller.scrollTop += box.top + anchor.fy * box.height - y;
	}

	private onWheel(evt: WheelEvent) {
		// Trackpad pinches arrive as wheel events with the Ctrl key set.
		if (!evt.ctrlKey && !evt.metaKey) {
			this.wheel = null;
			return;
		}
		evt.preventDefault();
		const last = this.wheel;
		const continues = last && last.x === evt.clientX && last.y === evt.clientY && evt.timeStamp - last.time < WHEEL_GESTURE_GAP;
		const anchor = continues ? last.anchor : this.anchorAt(evt.clientX, evt.clientY);
		this.wheel = { x: evt.clientX, y: evt.clientY, time: evt.timeStamp, anchor };

		const delta = Math.min(Math.max(evt.deltaY, -MAX_WHEEL_DELTA), MAX_WHEEL_DELTA);
		this.apply(this.zoom * Math.exp(-delta / 100), anchor, evt.clientX, evt.clientY);
	}

	private onTouchesChanged(evt: TouchEvent) {
		if (evt.touches.length !== 2) {
			this.pinch = null;
			return;
		}
		const pinch = measure(evt.touches);
		this.pinch = { ...pinch, anchor: this.anchorAt(pinch.x, pinch.y) };
	}

	private onTouchMove(evt: TouchEvent) {
		if (!this.pinch || evt.touches.length !== 2) return;
		// Scrolling is done here for as long as two fingers are down, to follow them exactly.
		if (evt.cancelable) evt.preventDefault();
		const now = measure(evt.touches);
		const zoom = this.pinch.distance > 0 ? (this.zoom * now.distance) / this.pinch.distance : this.zoom;
		this.apply(zoom, this.pinch.anchor, now.x, now.y);
		this.pinch = { ...now, anchor: this.pinch.anchor };
	}
}

function measure(touches: TouchList): Pinch {
	const [a, b] = [touches[0], touches[1]];
	return {
		distance: Math.hypot(b.clientX - a.clientX, b.clientY - a.clientY),
		x: (a.clientX + b.clientX) / 2,
		y: (a.clientY + b.clientY) / 2,
	};
}
