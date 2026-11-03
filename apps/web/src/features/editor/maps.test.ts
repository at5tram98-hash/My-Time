import { expect, it } from 'vitest';
import { googleMapsEmbedUrl, googleMapsUrl } from './maps';

it('住所を安全にエンコードし、位置情報の許可やAPIキーなしでGoogle Mapsへ渡す', () => {
  const url = new URL(googleMapsUrl({ name: 'GU & 京都', address: '京都市南区', lat: null, lng: null }));
  expect(url.origin).toBe('https://www.google.com');
  expect(url.searchParams.get('query')).toBe('GU & 京都 京都市南区');
  expect(url.searchParams.get('api')).toBe('1');
  const directions = new URL(googleMapsUrl({ name: '目的地', address: '', lat: 35, lng: 135 }, true));
  expect(directions.searchParams.get('destination')).toBe('35,135');
  expect(directions.searchParams.has('origin')).toBe(false);
});

it('埋め込みはGoogle Maps Embed APIだけを使用し、日本語の場所をエンコードする', () => {
  const u = new URL(googleMapsEmbedUrl({ name: '京都駅', address: '', lat: null, lng: null }, 'test-key'));
  expect(u.origin + u.pathname).toBe('https://www.google.com/maps/embed/v1/place');
  expect(u.searchParams.get('q')).toBe('京都駅');
  expect(u.searchParams.get('key')).toBe('test-key');
});
