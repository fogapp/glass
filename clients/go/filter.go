package glass

import "regexp"

// filterKeys is the gem's pattern (Glass::Config::FILTER_KEYS) and the Node
// client's, so a key is filtered or not whichever client saw it: the
// conformance kit's filter.json holds all three to it. RE2 has no
// lookahead, so the gem's token(?!s) is spelled token([^s]|$).
var filterKeys = regexp.MustCompile(`(?i)password|passwd|secret|token(?:[^s]|$)|api_key|apikey|access_key|auth|credential|cookie|session(?:_?id)?$`)

// Filtered is what a secret-looking key's value becomes. The key keeps its
// place; the value never leaves the process.
const Filtered = "[FILTERED]"

// FilteredKey reports whether a value under key is replaced by Filtered.
func FilteredKey(key string) bool { return filterKeys.MatchString(key) }

// attrValue is an attribute's value as it is sent: Filtered under a
// secret-looking key, otherwise the value said as a scalar.
func attrValue(key string, v any) any {
	if FilteredKey(key) {
		return Filtered
	}
	return scalar(v)
}
