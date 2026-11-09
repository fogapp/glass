/** The height of a row at 100%, in CSS pixels. */
export const ROW = 18;
/** Rows never shrink past this: thinner and a frame is no longer a mark. */
const MIN_ROW = 3;
/** The server prunes frames under 0.02% of the total; past this there is nothing left to see. */
export const MAX_SCALE = 1000;
/** One press of a zoom button or key. */
export const ZOOM_STEP = 1.5;

/**
 * What part of the tree the frame shows. One scale, two regimes: above 1
 * the tree stretches sideways (rows stay readable), below 1 the rows shrink
 * so a tree deeper than the frame fits in it. `x` and `y` are how far the
 * frame's corner sits into the tree, in CSS pixels.
 */
export interface View {
  scale: number;
  x: number;
  y: number;
}

/** The frame's size in CSS pixels and how many rows deep the tree is. */
export interface Extent {
  width: number;
  height: number;
  rows: number;
}

export const HOME: View = { scale: 1, x: 0, y: 0 };

export function rowHeight(scale: number): number {
  return ROW * Math.min(scale, 1);
}

/** The whole tree's size at a scale. */
export function treeSize(scale: number, extent: Extent): { width: number; height: number } {
  return { width: extent.width * Math.max(scale, 1), height: extent.rows * rowHeight(scale) };
}

/** The scale at which the whole tree fits the frame; 1 when it already does. */
export function fitScale(extent: Extent): number {
  if (extent.rows <= 0) return 1;
  return Math.min(1, Math.max(extent.height / (extent.rows * ROW), MIN_ROW / ROW));
}

/** A view the frame can actually show: scale in range, no panning past an edge. */
export function clampView(view: View, extent: Extent): View {
  const scale = Math.min(Math.max(view.scale, fitScale(extent)), MAX_SCALE);
  const size = treeSize(scale, extent);
  const x = Math.min(Math.max(view.x, 0), Math.max(size.width - extent.width, 0));
  const y = Math.min(Math.max(view.y, 0), Math.max(size.height - extent.height, 0));
  return scale === view.scale && x === view.x && y === view.y ? view : { scale, x, y };
}

/** Zoom to `scale`, keeping the point of the tree under (px, py) where it is. */
export function zoomAt(view: View, extent: Extent, scale: number, px: number, py: number): View {
  const from = treeSize(view.scale, extent);
  const next = clampView({ ...view, scale }, extent).scale;
  const to = treeSize(next, extent);
  const fx = from.width > 0 ? (view.x + px) / from.width : 0;
  const fy = from.height > 0 ? (view.y + py) / from.height : 0;
  return clampView({ scale: next, x: fx * to.width - px, y: fy * to.height - py }, extent);
}

export function panBy(view: View, extent: Extent, dx: number, dy: number): View {
  return clampView({ scale: view.scale, x: view.x + dx, y: view.y + dy }, extent);
}
