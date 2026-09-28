export class GeoUtil {
  static readonly EARTH_RADIUS_M: number = 6371000;

  private static toRad(degree: number): number {
    return degree * Math.PI / 180;
  }

  /** Haversine 球面距离（米），与参考项目一致 */
  static distanceM(lat1: number, lng1: number, lat2: number, lng2: number): number {
    const dLat: number = GeoUtil.toRad(lat2 - lat1);
    const dLng: number = GeoUtil.toRad(lng2 - lng1);
    const a: number = Math.sin(dLat / 2) * Math.sin(dLat / 2)
      + Math.cos(GeoUtil.toRad(lat1)) * Math.cos(GeoUtil.toRad(lat2))
      * Math.sin(dLng / 2) * Math.sin(dLng / 2);
    return GeoUtil.EARTH_RADIUS_M * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  }
}
