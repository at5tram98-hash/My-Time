import type { PlaceValue } from '@my-time/domain';

/** Official Maps URLs integration: no API key, paid SDK or location permission. */
export function googleMapsUrl(place: PlaceValue, directions = false): string {
  const query = place.lat != null && place.lng != null ? `${place.lat},${place.lng}` : [place.name, place.address].filter(Boolean).join(' ');
  const url = new URL(directions ? 'https://www.google.com/maps/dir/' : 'https://www.google.com/maps/search/');
  url.searchParams.set('api', '1');
  url.searchParams.set(directions ? 'destination' : 'query', query);
  return url.toString();
}
