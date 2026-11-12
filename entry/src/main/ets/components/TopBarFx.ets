/**
 * 顶栏「渐变模糊」可调参数（AppStorage 读取：tbx_blur / tbx_solid / tbx_fade；未写入时用代码默认值）。
 * 2026-11-10 起可在「界面布局 → 顶栏模糊」里由用户调节（UsageHabitsManager.setTopBarFx 落盘 + 恢复）。
 * blur 是模糊半径，solid 和 fade 分别是实心段和渐退段的结束位置。
 * fade 为 0 时关闭渐变模糊，其他档位的 fade 须大于 solid。
 *
 * 所有挂载点统一按 `.linearGradientBlur(TopBarFx.blur(this.tbxTick), {...})` 取值：
 * rev 是 `@StorageLink('topBarFxTick')` 重绘令牌 —— 设置页改档时 bump tick，各页在 build 期
 * 读到该状态即重绘，从而拿到新的 AppStorage 值（AppStorage.get 本身不参与状态订阅）。
 */
export class TopBarFx {
  /** 最终模糊半径默认值（vp） */
  static readonly DEFAULT_BLUR: number = 26;
  /** 最终模糊半径上限（vp） */
  static readonly MAX_BLUR: number = 60;
  /** 全模糊段结束位置默认值（0~1） */
  static readonly DEFAULT_SOLID: number = 0.10;
  /** 渐退段结束位置默认值（0~1） */
  static readonly DEFAULT_FADE: number = 0.14;

  /** 最终模糊半径（vp，0~60）；rev 仅建立构建期状态依赖，不参与计算 */
  static blur(rev: number = 0): number {
    if (AppStorage.get<number>('tbx_fade') === 0) {
      return 0;
    }
    const v: number = (AppStorage.get<number>('tbx_blur') ?? TopBarFx.DEFAULT_BLUR) + rev * 0;
    return Math.max(0, Math.min(TopBarFx.MAX_BLUR, v));
  }

  /** 全模糊段结束位置（0~1，须小于 fade）；rev 仅建立构建期状态依赖 */
  static solid(rev: number = 0): number {
    const v: number = (AppStorage.get<number>('tbx_solid') ?? TopBarFx.DEFAULT_SOLID) + rev * 0;
    return Math.max(0, Math.min(0.9, v));
  }

  /** 渐变停止位置。模糊关闭时仍向 ArkUI 提供有序的停止位置。 */
  static fade(rev: number = 0): number {
    const v: number = (AppStorage.get<number>('tbx_fade') ?? TopBarFx.DEFAULT_FADE) + rev * 0;
    return Math.max(0.02, Math.min(1, v));
  }
}
