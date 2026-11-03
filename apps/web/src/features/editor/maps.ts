import type { PlaceValue } from '@my-time/domain';

/** Official Maps URLs integration: no API key, paid SDK or location permission. */
export function googleMapsUrl(place: PlaceValue, directions = false): string {
  const query = place.lat != null && place.lng != null ? `${place.lat},${place.lng}` : [place.name, place.address].filter(Boolean).join(' ');
  const url = new URL(directions ? 'https://www.google.com/maps/dir/' : 'https://www.google.com/maps/search/');
  url.searchParams.set('api', '1');
  url.searchParams.set(directions ? 'destination' : 'query', query);
  return url.toString();
}

/** APIキーはGoogle Cloud側で公開オリジンとMaps Embed APIだけに制限する。 */
export function googleMapsEmbedUrl(place: PlaceValue, key: string): string {
  const url = new URL('https://www.google.com/maps/embed/v1/place');
  url.searchParams.set('key', key);
  url.searchParams.set('q', place.lat != null && place.lng != null ? `${place.lat},${place.lng}` : [place.name, place.address].filter(Boolean).join(' '));
  url.searchParams.set('language', 'ja');
  return url.toString();
}
