/**
 * DOM helpers for locating elements and extracting agent-useful context:
 * a stable CSS selector path, a build-time source hint, and the React
 * component name.
 */
import type { FlanInspectorSelection } from './types.js';

/**
 * Builds a reasonably stable, reasonably short CSS selector for [el].
 *
 * Strategy per ancestor: prefer `#id` (and stop — ids are unique), else
 * tag + `:nth-of-type(n)` among same-tag siblings. Walks up to the body.
 */
export function cssSelectorFor(el: Element): string {
  if (!(el instanceof Element)) return '';
  const parts: string[] = [];
  let current: Element | null = el;

  while (current && current.nodeType === Node.ELEMENT_NODE) {
    if (current.id) {
      parts.unshift(`#${cssEscape(current.id)}`);
      break;
    }
    const tag = current.tagName.toLowerCase();
    if (tag === 'body' || tag === 'html') {
      parts.unshift(tag);
      break;
    }
    const parent: Element | null = current.parentElement;
    if (!parent) {
      parts.unshift(tag);
      break;
    }
    const sameTag = Array.from(parent.children).filter(
      (c) => c.tagName === current!.tagName,
    );
    if (sameTag.length > 1) {
      const index = sameTag.indexOf(current) + 1;
      parts.unshift(`${tag}:nth-of-type(${index})`);
    } else {
      parts.unshift(tag);
    }
    current = parent;
  }
  return parts.join(' > ');
}

/** CSS.escape with a manual fallback for older runtimes. */
function cssEscape(value: string): string {
  const cssGlobal = (
    globalThis as { CSS?: { escape?: (s: string) => string } }
  ).CSS;
  if (cssGlobal && typeof cssGlobal.escape === 'function') {
    return cssGlobal.escape(value);
  }
  return value.replace(/[^a-zA-Z0-9_-]/g, '\\$&');
}

/**
 * Reads a `data-flan-source` attribute, if present, from [el] or its
 * nearest ancestor. A Babel/Vite plugin can stamp these as
 * `data-flan-source="src/Button.tsx:42"` to give the agent a file:line.
 */
export function sourceHintFor(el: Element): string | undefined {
  let current: Element | null = el;
  while (current) {
    const hint = current.getAttribute('data-flan-source');
    if (hint) return hint;
    current = current.parentElement;
  }
  return undefined;
}

/**
 * Best-effort React component display name for the DOM node [el].
 *
 * React stores a fiber on the DOM node under a `__reactFiber$…` key.
 * Walks up the fiber's `return` chain to the nearest function/class
 * component and returns its name. Returns undefined if React internals
 * are not present (production builds may mangle names).
 */
export function componentNameFor(el: Element): string | undefined {
  const fiberKey = Object.keys(el).find(
    (k) =>
      k.startsWith('__reactFiber$') ||
      k.startsWith('__reactInternalInstance$'),
  );
  if (!fiberKey) return undefined;

  let fiber = (el as unknown as Record<string, unknown>)[fiberKey] as
    | FiberNode
    | undefined;

  let depth = 0;
  while (fiber && depth < 30) {
    const type = fiber.type;
    if (typeof type === 'function') {
      const name = (type as { displayName?: string; name?: string })
        .displayName ||
        (type as { name?: string }).name;
      if (name && name !== 'Unknown') return name;
    } else if (
      type &&
      typeof type === 'object' &&
      'displayName' in (type as object)
    ) {
      const dn = (type as { displayName?: string }).displayName;
      if (dn) return dn;
    }
    fiber = fiber.return;
    depth += 1;
  }
  return undefined;
}

interface FiberNode {
  type: unknown;
  return?: FiberNode;
}

/** Trimmed, length-capped text content of [el]. */
export function shortText(el: Element, max = 80): string | undefined {
  const text = (el.textContent ?? '').trim().replace(/\s+/g, ' ');
  if (!text) return undefined;
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

/** Viewport-pixel bounding box [x, y, width, height] of [el]. */
export function boxOf(el: Element): [number, number, number, number] {
  const r = el.getBoundingClientRect();
  return [
    Math.round(r.x),
    Math.round(r.y),
    Math.round(r.width),
    Math.round(r.height),
  ];
}

/** Captures a full {@link FlanInspectorSelection} for [el]. */
export function describeElement(el: Element): FlanInspectorSelection {
  return {
    tagName: el.tagName.toLowerCase(),
    selector: cssSelectorFor(el),
    text: shortText(el),
    box: boxOf(el),
    sourceHint: sourceHintFor(el),
    componentName: componentNameFor(el),
  };
}

/**
 * Returns the topmost element at viewport point (x, y), skipping any
 * node inside a Flan overlay (marked with `data-flan-overlay`).
 */
export function elementAtPoint(x: number, y: number): Element | null {
  const stack = document.elementsFromPoint(x, y);
  for (const el of stack) {
    if (!el.closest('[data-flan-overlay]')) {
      return el;
    }
  }
  return null;
}
