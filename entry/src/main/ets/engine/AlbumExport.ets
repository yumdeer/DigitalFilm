/**
 * 相册写入：走系统「保存到图库」确认框，应用本身不需要存储权限。
 * 编辑页导出与相机页快门直出共用。
 */
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

export async function saveToAlbum(ctx: common.UIAbilityContext, path: string,
                                  ext: string): Promise<boolean> {
  try {
    const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
    const cfg: photoAccessHelper.PhotoCreationConfig = {
      title: 'DigitalFilm_' + Date.now(),
      fileNameExtension: ext,
      photoType: photoAccessHelper.PhotoType.IMAGE
    };
    const tmpUri: string = fileUri.getUriFromPath(path);
    const uris: string[] = await helper.showAssetsCreationDialog([tmpUri], [cfg]);
    if (uris.length === 0) {
      return false;
    }
    const dest = fs.openSync(uris[0], fs.OpenMode.READ_WRITE);
    fs.copyFileSync(path, dest.fd);
    fs.closeSync(dest);
    return true;
  } catch (e) {
    return false;
  }
}
