/**
 * Convert an arbitrary string into a URL-safe slug.
 *
 * Pure, deterministic, no side effects.
 *
 * Transformation pipeline, in order:
 *   1. Coerce/guard input to a string (String(str)).
 *   2. Lowercase the whole string.
 *   3. Trim leading/trailing whitespace.
 *   4. Replace every run of non-alphanumeric chars ([^a-z0-9]+) with a SINGLE hyphen.
 *   5. Strip any leading and trailing hyphens from the result.
 *
 * @param {string} str - the input string to slugify
 * @returns {string} the slugified string
 */
export function slugify(str) {
  if (str === null || str === undefined) return '';
  return String(str)
    .toLowerCase()
    .trim()
    // collapse any run of non-alphanumeric chars into a single hyphen
    .replace(/[^a-z0-9]+/g, '-')
    // strip leading/trailing hyphens
    .replace(/^-+|-+$/g, '');
}

// Alias kept for callers that import the shorter name.
export const slug = slugify;

export default slugify;
