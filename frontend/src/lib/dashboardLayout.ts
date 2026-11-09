/**
 * A dashboard's grid (`Dashboard` on the server): twelve columns, rows of a
 * fixed height, every widget a rectangle in those units. Widgets fall
 * upward — a dashboard has no holes — so where a widget sits is decided by
 * its order and its size, and moving or resizing one is a new order and a
 * new size, settled again.
 */
export interface Cell {
  id: string;
  x: number;
  y: number;
  w: number;
  h: number;
  /** The fewest rows it may take, when not `MIN_H` (a header's single line). */
  minH?: number;
}

export const COLUMNS = 12;
/** The server keeps to the same bounds (`Dashboard::MIN_W` and friends). */
export const MIN_W = 2;
export const MIN_H = 4;
export const MAX_H = 20;

export function overlaps(a: Cell, b: Cell): boolean {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
}

function sharesColumns(a: Cell, b: Cell): boolean {
  return a.x < b.x + b.w && b.x < a.x + a.w;
}

/** Reading order: top to bottom, then left to right. */
export function byPosition(a: Cell, b: Cell): number {
  return a.y - b.y || a.x - b.x;
}

/** A cell kept inside the grid and the sizes a widget may take. */
export function clamp(cell: Cell): Cell {
  const w = Math.min(Math.max(Math.round(cell.w), MIN_W), COLUMNS);
  const h = Math.min(Math.max(Math.round(cell.h), cell.minH ?? MIN_H), MAX_H);
  const x = Math.min(Math.max(Math.round(cell.x), 0), COLUMNS - w);
  return { ...cell, x, y: Math.max(Math.round(cell.y), 0), w, h };
}

/** Let each cell rise as far as it can, in the order given: earlier cells settle first. */
export function settle(sequence: Cell[]): Cell[] {
  const placed: Cell[] = [];
  for (const cell of sequence) {
    const next = { ...cell, y: 0 };
    for (let hit = placed.find((other) => overlaps(next, other)); hit; hit = placed.find((other) => overlaps(next, other))) {
      next.y = hit.y + hit.h;
    }
    placed.push(next);
  }
  return placed;
}

/** A stored layout made whole: inside the grid, no overlaps, no holes. */
export function compact(cells: Cell[]): Cell[] {
  return settle(cells.map(clamp).sort(byPosition));
}

/**
 * Where everything lands while `id` is held at column `x` with its top at
 * `top` rows (fractions allowed — it follows the pointer). It goes after a
 * widget in its columns once its leading edge passes that widget's middle:
 * its bottom edge when it started above, its top edge when it started level
 * with it or below.
 */
export function moveCell(layout: Cell[], id: string, x: number, top: number): Cell[] {
  const moving = layout.find((cell) => cell.id === id);
  if (!moving) return layout;
  const target = clamp({ ...moving, x });
  const others = layout.filter((cell) => cell.id !== id).sort(byPosition);
  const from = Math.max(top, 0);
  let after = -1;
  others.forEach((other, index) => {
    if (!sharesColumns(target, other)) return;
    const middle = other.y + other.h / 2;
    const startedAbove = moving.y < other.y;
    if (startedAbove ? from + moving.h > middle : from >= middle) after = index;
  });
  return settle([...others.slice(0, after + 1), target, ...others.slice(after + 1)]);
}

/**
 * Where everything lands when `id` takes `w` × `h`, keeping its corner. It
 * holds its place, and what it grows into makes way.
 */
export function resizeCell(layout: Cell[], id: string, w: number, h: number): Cell[] {
  const resizing = layout.find((cell) => cell.id === id);
  if (!resizing) return layout;
  const target = clamp({ ...resizing, w: Math.min(w, COLUMNS - resizing.x), h });
  const sequence = [...layout].sort(byPosition);
  const own = sequence.findIndex((cell) => cell.id === id);
  sequence.splice(own, 1);
  const blocking = sequence.findIndex((cell) => overlaps(target, cell));
  const at = blocking === -1 ? own : Math.min(own, blocking);
  return settle([...sequence.slice(0, at), target, ...sequence.slice(at)]);
}

/**
 * The keyboard's move: a column left or right, or past the nearest widget
 * above or below in the same columns.
 */
export function nudgeCell(layout: Cell[], id: string, dx: number, dy: number): Cell[] {
  const cell = layout.find((each) => each.id === id);
  if (!cell) return layout;
  if (dx !== 0) return moveCell(layout, id, cell.x + dx, cell.y);
  const neighbours = layout.filter((other) => other.id !== id && sharesColumns(cell, other) && (dy > 0 ? other.y > cell.y : other.y < cell.y));
  if (neighbours.length === 0) return layout;
  const nearest = neighbours.sort((a, b) => (dy > 0 ? a.y - b.y : b.y - a.y))[0]!;
  const middle = nearest.y + nearest.h / 2;
  return moveCell(layout, id, cell.x, dy > 0 ? middle - cell.h + 0.5 : middle - 0.5);
}

/** Whether two layouts put every widget in the same place. */
export function sameLayout(a: Cell[], b: Cell[]): boolean {
  if (a.length !== b.length) return false;
  const places = new Map(a.map((cell) => [cell.id, cell]));
  return b.every((cell) => {
    const other = places.get(cell.id);
    return other !== undefined && other.x === cell.x && other.y === cell.y && other.w === cell.w && other.h === cell.h;
  });
}

/** How many rows the layout takes. */
export function rows(cells: Cell[]): number {
  return cells.reduce((bottom, cell) => Math.max(bottom, cell.y + cell.h), 0);
}
