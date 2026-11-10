/**
 * 隐私政策告知：相机页与编辑页共用同一份文案、同一个同意状态。
 *
 * 合规要求：在用户明确同意前，不申请相机权限、不读取相册、不加载素材。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

export const PRIVACY_URL: string = 'https://yumdeer.github.io/DigitalFilm/privacy.html';
export const PREF_STORE: string = 'digitalfilm_prefs';
export const PREF_PRIVACY_KEY: string = 'privacy_agreed_v1';

export const PRIVACY_BODY_ZH: string =
  'DigitalFilm 是一款完全在本地运行的胶片模拟相机：不采集、不上传任何个人信息。' +
  '相机权限仅用于应用内的取景与快门拍摄，取景画面与拍摄的照片都只在本机内存中参与胶片冲印；' +
  '你从相册选择的照片同样只在本机渲染。成片由系统「保存到图库」确认框写入相册，无需授予存储权限。';

export async function readPrivacyAgreed(ctx: common.Context): Promise<boolean> {
  try {
    const pref: preferences.Preferences = await preferences.getPreferences(ctx, PREF_STORE);
    return pref.getSync(PREF_PRIVACY_KEY, false) as boolean;
  } catch (e) {
    return false;
  }
}

export async function writePrivacyAgreed(ctx: common.Context): Promise<void> {
  try {
    const pref: preferences.Preferences = await preferences.getPreferences(ctx, PREF_STORE);
    pref.putSync(PREF_PRIVACY_KEY, true);
    await pref.flush();
  } catch (e) {
    // 写入失败则下次启动再询问一次，不影响本次使用。
  }
}
