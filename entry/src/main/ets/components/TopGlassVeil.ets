import { isDarkMode } from '../common/Theme';

/**
 * 顶栏玻璃质感层（2026-11-10）：补全官方材质三要素，让渐变模糊「有质感」。
 *
 * 根因：linearGradientBlur 只有「模糊」一个成分；官方 App 顶栏的磨砂玻璃感来自
 * ①饱和度提升（vibrancy）②乳白/乳黑半透明蒙版 ③亮度微调 —— 调 blur/solid/fade
 * 任何组合都调不出来。本组件以 .overlay() 挂在各页模糊容器上（默认 TopStart），
 * 叠在已渐变模糊的内容之上、Navigation title 槽位（顶栏按钮/标题）之下：
 *
 * - 玻璃层（0~108vp）：backgroundEffect 只做饱和度+亮度（radius 2 仅保持效果管线激活，
 *   不叠加二次模糊）；其底缘的饱和度落差由乳色渐变层同位置的余量盖住；
 * - 乳色层（0~184vp）：应用背景色系的白/黑 → 透明线性渐变（无全实段、无硬边，
 *   守 2026-09-14「全实段硬切被驳回」教训），与内容侧 linearGradientBlur 的渐退带
 *   叠加成「液态玻璃」观感。
 *
 * hitTestBehavior None：纯装饰层不挡触摸（老 GradientBlurBar 同款）。
 * 本层不随「顶栏模糊」滑杆变化（滑杆只管模糊几何）；深浅色随 darkTick 联动。
 */
@Component
export struct TopGlassVeil {
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;
  @State isDark: boolean = false;

  aboutToAppear(): void {
    this.isDark = isDarkMode();
  }

  onDarkTick(): void {
    this.isDark = isDarkMode();
  }

  build() {
    Stack() {
      // 玻璃层：官方材质的 vibrancy（饱和度）+ 亮度微调，仅覆盖状态栏+顶栏高度
      Column()
        .width('100%')
        .height(108)
        .backgroundEffect({
          radius: 2,
          saturation: this.isDark ? 1.30 : 1.35,
          brightness: this.isDark ? 1.02 : 1.04,
          color: this.isDark ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.10)'
        })

      // 乳色层：应用背景色系的半透明渐变（无全实段），盖住玻璃层底缘落差并向下渐隐
      Column()
        .width('100%')
        .height(184)
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: this.isDark
            ? [['rgba(16,17,20,0.42)', 0.0], ['rgba(16,17,20,0.28)', 0.55], ['rgba(16,17,20,0)', 1.0]]
            : [['rgba(242,244,247,0.55)', 0.0], ['rgba(242,244,247,0.36)', 0.55], ['rgba(242,244,247,0)', 1.0]]
        })
    }
    .width('100%')
    .height(184)
    .alignContent(Alignment.TopStart)
    .hitTestBehavior(HitTestMode.None)
  }
}
