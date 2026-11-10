/**
 * 胶卷陈列用的静态元数据：色条、片基说明、厂商与 ISO 标记。
 * 编辑页的胶片库和相机页的胶卷滑条共用，保证两边对同一款胶卷的叫法一致。
 */
import { FilmAssets } from '../engine/SpectralEngine';

/** Stocks that ship a rendered 135 cartridge / 120 roll illustration. */
export const FILM_ART_STOCKS: string[] = [
  'kodak_portra_160', 'kodak_portra_400', 'kodak_portra_800',
  'kodak_portra_800_push1', 'kodak_portra_800_push2',
  'kodak_ektar_100', 'kodak_gold_200', 'kodak_ultramax_400',
  'kodak_ektachrome_100', 'kodak_kodachrome_64', 'kodak_verita_200d',
  'kodak_vision3_50d', 'kodak_vision3_250d', 'kodak_vision3_200t',
  'kodak_vision3_500t',
  'fujifilm_c200', 'fujifilm_xtra_400', 'fujifilm_pro_400h',
  'fujifilm_velvia_100', 'fujifilm_provia_100f',
  'cinestill_800t', 'ilford_hp5_plus_400', 'kodak_tmax_100',
  'fujifilm_neopan_acros_100_ii'
];

/** 每款胶卷在 UI 上的代表色。 */
export function filmTint(id: string): string {
  if (id.indexOf('portra_400') >= 0) { return '#C89A78'; }
  if (id.indexOf('portra_160') >= 0) { return '#D2AC92'; }
  if (id.indexOf('portra_800') >= 0) { return '#B98A6B'; }
  if (id.indexOf('ektar') >= 0) { return '#C4523E'; }
  if (id.indexOf('gold') >= 0) { return '#D9A441'; }
  if (id.indexOf('ultramax') >= 0) { return '#C88A4A'; }
  if (id.indexOf('400h') >= 0) { return '#A6BAAE'; }
  if (id.indexOf('c200') >= 0) { return '#C9B48F'; }
  if (id.indexOf('250d') >= 0) { return '#8FA3B8'; }
  if (id.indexOf('500t') >= 0) { return '#6E7F96'; }
  if (id.indexOf('50d') >= 0) { return '#9CB3C6'; }
  if (id.indexOf('200t') >= 0) { return '#7E8FA6'; }
  if (id.indexOf('verita') >= 0) { return '#8C9DB0'; }
  if (id.indexOf('cinestill') >= 0) { return '#B4544A'; }
  if (id.indexOf('xtra') >= 0) { return '#C4B08A'; }
  if (id.indexOf('push') >= 0) { return '#B49A78'; }
  if (id.indexOf('hp5') >= 0) { return '#A8B2A2'; }
  if (id.indexOf('tmax') >= 0) { return '#7C7C78'; }
  if (id.indexOf('acros') >= 0) { return '#8E9A8C'; }
  return '#9A9A96';
}

/** 片基类型的一行小字。 */
export function filmFlags(f: FilmAssets): string {
  if (f.type === 'positive') { return 'SLIDE  POSITIVE'; }
  if (f.channelModel === 'bw') { return 'B&W  NEGATIVE'; }
  if (f.id.indexOf('vision3') >= 0 || f.id.indexOf('verita') >= 0) {
    return 'CINE  NEGATIVE';
  }
  return 'COLOR  NEGATIVE';
}

/** Short maker mark stamped on the drawn canister. */
export function filmBrand(name: string): string {
  if (name.indexOf('Fujifilm') === 0) { return 'FUJIFILM'; }
  if (name.indexOf('Ilford') === 0) { return 'ILFORD'; }
  if (name.indexOf('CineStill') === 0) { return 'CINESTILL'; }
  return 'KODAK';
}

/** First 2-4 digit group in the stock name is its ISO rating. */
export function filmIsoFromName(name: string): string {
  let digits: string = '';
  for (let i = 0; i < name.length; i++) {
    const c: string = name.charAt(i);
    if (c >= '0' && c <= '9') {
      digits += c;
    } else if (digits.length >= 2) {
      break;
    } else if (digits.length === 1) {
      digits = '';
    }
  }
  return digits.length > 0 ? digits : 'FILM';
}

export function filmIso(f: FilmAssets): string {
  return filmIsoFromName(f.name);
}

/** Drop the maker prefix: "Kodak Portra 400" -> "Portra 400". */
export function filmShortName(name: string): string {
  const space: number = name.indexOf(' ');
  return space > 0 ? name.substring(space + 1) : name;
}

export function isCineFilm(f: FilmAssets): boolean {
  return f.id.indexOf('vision3') >= 0 || f.id.indexOf('verita') >= 0;
}
