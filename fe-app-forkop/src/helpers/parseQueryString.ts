export function parseQueryString(query: string): Record<string, string> {
  const clean = query.startsWith('?') ? query.slice(1) : query;

  return clean
    .split('&')
    .filter(Boolean)
    .reduce(
      (acc, pair) => {
        const [rawKey, rawValue = ''] = pair.split('=');

        if (!rawKey) {
          return acc;
        }

        let key = rawKey;
        let value = rawValue;
        try {
          key = decodeURIComponent(rawKey);
        } catch {
          /* keep raw */
        }
        try {
          value = decodeURIComponent(rawValue);
        } catch {
          /* keep raw */
        }

        return { ...acc, [key]: value };
      },
      {} as Record<string, string>,
    );
}
