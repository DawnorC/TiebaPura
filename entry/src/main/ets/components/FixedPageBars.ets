import { window } from '@kit.ArkUI';

/** Reserve system bar space for pages hosted in the full-screen application window. */
@Component
export struct FixedPageBars {
  @BuilderParam content: () => void = this.emptyContent;
  @Prop topColor: ResourceColor = Color.White;
  @Prop bottomColor: ResourceColor = Color.White;
  @State topInset: number = 44;
  @State bottomInset: number = 12;
  private mounted: boolean = true;

  @Builder
  emptyContent() {}

  aboutToDisappear(): void {
    this.mounted = false;
  }

  private async updateInsets(): Promise<void> {
    const ui = this.getUIContext();
    const context = ui.getHostContext();
    if (!context) {
      return;
    }
    try {
      const mainWindow = await window.getLastWindow(context);
      const system = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navigation = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      if (this.mounted) {
        this.topInset = ui.px2vp(system.topRect.height);
        this.bottomInset = ui.px2vp(Math.max(system.bottomRect.height, navigation.bottomRect.height));
      }
    } catch (e) {
      // Keep the fallback until the window's avoid areas become available.
    }
  }

  build() {
    Column() {
      Column().width('100%').height(this.topInset).backgroundColor(this.topColor)
      Column() {
        this.content()
      }
      .width('100%')
      .layoutWeight(1)
      .clip(true)
      Column().width('100%').height(this.bottomInset).backgroundColor(this.bottomColor)
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      if (oldArea.width !== newArea.width || oldArea.height !== newArea.height) {
        this.updateInsets();
      }
    })
  }
}
