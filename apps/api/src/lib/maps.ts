import type { PlaceValue } from '@my-time/domain';

/** 必要なフィールドだけ取得。結果の保存は利用者が場所を選んだときだけ。キーをログに出さない。 */
export async function searchGooglePlaces(query: string, key: string): Promise<PlaceValue[]> {
  const response = await fetch('https://places.googleapis.com/v1/places:searchText', {
    method: 'POST', headers: { 'content-type': 'application/json', 'X-Goog-Api-Key': key, 'X-Goog-FieldMask': 'places.displayName,places.formattedAddress,places.location' },
    body: JSON.stringify({ textQuery: query, languageCode: 'ja', regionCode: 'JP', pageSize: 8 }), signal: AbortSignal.timeout(8000),
  });
  if (!response.ok) throw new Error('Google Maps search unavailable');
  const body = await response.json() as { places?: { displayName?: { text?: string }; formattedAddress?: string; location?: { latitude: number; longitude: number } }[] };
  return (body.places ?? []).flatMap((p) => p.displayName?.text ? [{ name: p.displayName.text, address: p.formattedAddress ?? '', lat: p.location?.latitude ?? null, lng: p.location?.longitude ?? null }] : []);
}
