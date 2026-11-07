/**
 * Tokens lifted from the reference implementation Filmroom 0.1.20
 * (`dev.filmroom.ui.FilmroomPalette`): neutral near-black workbench,
 * amber accent used as the single active colour, dark ink on accent.
 */
export class Theme {
  static ground: string = '#181818';    // background
  static card: string = '#222222';      // surface
  static cardRaised: string = '#2C2C2C';// raised (selected surface)
  static rule: string = '#3B3B3B';      // divider
  static plot: string = '#141414';      // inset (canvas / plots)
  static text: string = '#F1F1F1';      // ink
  static secondary: string = '#B8B8B8'; // muted
  static ruler: string = '#DCDCDC';     // ruler / numeric readout
  static track: string = '#464646';     // inactive track
  static dim: string = '#7A7A7A';
  static accent: string = '#E5A35D';
  static selection: string = '#E5A35D';
  static onSelection: string = '#181818';
  static disabled: number = 0.38;
}
