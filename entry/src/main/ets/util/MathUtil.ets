export class MathUtil {
  static clamp(value: number, min: number, max: number): number {
    if (value < min) {
      return min;
    }
    if (value > max) {
      return max;
    }
    return value;
  }

  static round1(value: number): number {
    return Math.round(value * 10) / 10;
  }
}
