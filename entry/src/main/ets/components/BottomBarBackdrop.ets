@Component
export struct BottomBarBackdrop {
  @Prop heightVp: number = 100;
  @Prop isDark: boolean = false;

  build() {
    Column()
      .width('100%')
      .height(this.heightVp)
      .backgroundEffect({ radius: 4, color: Color.Transparent })
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [[Color.Transparent, 0], [this.isDark ? '#99000000' : '#CCF1F3F5', 1]]
      })
      .hitTestBehavior(HitTestMode.None)
  }
}
