/*
 * 界面布局设置页
 * ---------------------------------------------------------------------------
 * 提供以下可保存的界面偏好：
 *   1) 页面边距——主页面/设置页内容左右留白（0~24vp，0 = 贴边）
 *   2) Dock 栏顺序——底部导航栏五个入口的排列顺序（长按拖动排序）
 *   3) Dock 隐藏项——可隐藏某个入口（如隐藏「首页」，底栏只剩四项；至少保留一项）
 *   4) 默认显示界面——进入应用后默认停留的 Tab
 *   5) 切页动画开关——主界面切换是否播放左右平移
 *   6) 列数调整——大屏形态列表列数三选一（自「个性化」页并入）
 *   7) 吧主页默认排序——进入吧主页时默认显示的排序（自「使用习惯」页并入）
 *   8) 关闭自动旋转——仅阔直屏直板显示（自「使用习惯」页并入）
 * 真源统一走 AppStorage（pageMargin / dockOrder / dockHidden / defaultTab / tabAnimEnabled /
 * columnMode / forumDefaultSort / autoRotateOff），并通过 UsageHabitsManager 落盘 + 冷启动恢复，
 * 各页以 @StorageLink 实时响应。
 *
 * 页面框架与「软件设置」（Settings.ets）完全一致：API26+ 走官方材质标题栏（title 槽位，
 * ImmMaterial.seg(false) 圆钮自带清晰边缘），否则回退页面主体自绘玻璃 TopBar。
 */
import { display } from '@kit.ArkUI';
import { UsageHabitsManager } from '../service/UsageHabitsManager';
import { TopBarFx } from '../components/TopBarFx';
import { TopGlassVeil } from '../components/TopGlassVeil';
import {
  DEFAULT_PAGE_MARGIN, DEFAULT_CARD_RADIUS_SCALE, DEFAULT_RECENT_AVATAR_SIZE,
  Theme, Spacing, Radius, isDarkMode, ImmBlur, ImmMaterial, MaterialManager, fs, tabletTopFadeStop,
  columnModeLabel, isWideBarFlatDevice
} from '../common/Theme';
import { BRAND_BLUE } from '../common/Constants';

/** 官方标题栏槽位高度：44(状态栏让位) + 44(按钮行高) + 10(底部呼吸)，与 Settings 一致 */
const LAYOUT_TITLE_BAR_HEIGHT: number = 98;
/** 官方材质标题栏开关（与 Settings 的 SETTINGS_OFFICIAL_TITLE_BAR 同判据） */
const LAYOUT_OFFICIAL_TITLE_BAR: boolean = true;

/** 「列数调整」档位选项：0 = 默认（按机型自动适配）/ 1 = 竖二横三 / 2 = 竖三横四 */
const COLUMN_MODE_OPTIONS: number[] = [0, 1, 2];
/** 「吧主页默认进入界面」档位选项：0 = 热门（默认）/ 1 = 最新 / 2 = 精选 */
const FORUM_SORT_OPTIONS: number[] = [0, 1, 2];

/** Dock 顺序中的单个 Tab 元数据 */
class DockTabMeta {
  index: number;
  label: string;
  icon: string;

  constructor(index: number, label: string, icon: string) {
    this.index = index;
    this.label = label;
    this.icon = icon;
  }
}

const DOCK_TABS: DockTabMeta[] = [
  new DockTabMeta(0, '首页', '⌂'),
  new DockTabMeta(1, '进吧', '▦'),
  new DockTabMeta(2, '收藏', '★'),
  new DockTabMeta(3, '消息', '✉'),
  new DockTabMeta(4, '我的', '♙'),
];

/**
 * 「列数调整」三选一弹窗（系统 CustomDialog + API 26 沉浸光感，自「个性化」页原样迁入）。
 * 玻璃层交给 options.systemMaterial（ImmMaterial.dialog()），卡内不再自绘玻璃。
 */
@CustomDialog
struct ColumnModeDialog {
  @StorageLink('cardRadiusScale') cardRadiusScale: number = DEFAULT_CARD_RADIUS_SCALE;
  /** 系统弹窗必须声明 CustomDialogController 类型属性（ArkTS 编译期强校验） */
  controller?: CustomDialogController;
  @Link isDark: boolean;
  @Link fontScale: number;
  /** 当前档位（0/1/2）：选中项高亮用 */
  @Link mode: number;
  /** 选定档位回调（写 AppStorage + 落盘 + 广播 columnModeTick） */
  onPick: (mode: number) => void = () => {};
  onDismiss: () => void = () => {};

  /** 档位说明（选项副文案） */
  private optionNote(m: number): string {
    if (m === 1) {
      return '竖屏 2 列 · 横屏 3 列';
    }
    if (m === 2) {
      return '竖屏 3 列 · 横屏 4 列';
    }
    return '按设备与横竖屏自动适配';
  }

  build() {
    Column({ space: Spacing.md }) {
      Text('列数调整')
        .fontSize(fs(17, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
        .textAlign(TextAlign.Center)
        .width('100%')

      Text('仅在大屏设备（平板 / 阔直屏 / 折叠屏展开）生效，手机不受影响')
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textTertiary(this.isDark))
        .textAlign(TextAlign.Center)
        .width('100%')

      ForEach(COLUMN_MODE_OPTIONS, (m: number) => {
        Row({ space: Spacing.sm }) {
          Column({ space: 2 }) {
            Text(columnModeLabel(m))
              .fontSize(fs(15, this.fontScale))
              .fontWeight(this.mode === m ? FontWeight.Bold : FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.isDark))
            Text(this.optionNote(m))
              .fontSize(fs(11, this.fontScale))
              .fontColor(Theme.textTertiary(this.isDark))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          if (this.mode === m) {
            SymbolGlyph($r('sys.symbol.checkmark_circle'))
              .fontColor([Theme.brand()])
              .fontSize(fs(20, this.fontScale))
          }
        }
        .width('100%')
        .padding({ left: Spacing.md, right: Spacing.md, top: Spacing.md, bottom: Spacing.md })
        .backgroundColor(this.mode === m ? (this.isDark ? '#333173FF' : '#1A3173FF') : Color.Transparent)
        .borderRadius(Radius.md * this.cardRadiusScale)
        .onClick(() => { this.onPick(m); })
      }, (m: number) => `column_mode_${m}`)

      Button() {
        Text('取消')
          .fontSize(fs(15, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
      }
      .width('100%')
      .height(44)
      .systemMaterial(ImmMaterial.cardAction())
      .backgroundColor(this.isDark ? '#B31B1E24' : '#B3FFFFFF')
      .borderRadius(Radius.full)
      .shadow({ radius: 10, color: this.isDark ? '#4D000000' : '#1F101824', offsetY: 3 })
      .onClick(() => { this.onDismiss(); })
    }
    .width('100%')
    .padding(Spacing.lg)
  }
}

/**
 * 「吧主页默认进入界面」三选一弹窗（系统 CustomDialog + API 26 沉浸光感，自「使用习惯」页原样迁入）。
 */
@CustomDialog
struct ForumDefaultSortDialog {
  @StorageLink('cardRadiusScale') cardRadiusScale: number = DEFAULT_CARD_RADIUS_SCALE;
  /** 系统弹窗必须声明 CustomDialogController 类型属性（ArkTS 编译期强校验） */
  controller?: CustomDialogController;
  @Link isDark: boolean;
  @Link fontScale: number;
  /** 当前档位（0 = 热门 / 1 = 最新 / 2 = 精选）：选中项高亮用 */
  @Link mode: number;
  /** 选定档位回调（写 AppStorage + 落盘） */
  onPick: (mode: number) => void = () => {};
  onDismiss: () => void = () => {};

  /** 档位说明 */
  private optionNote(m: number): string {
    if (m === 1) {
      return '吧主页打开先显示最新排序';
    }
    if (m === 2) {
      return '吧主页打开先显示精选排序';
    }
    return '吧主页打开先显示热门排序';
  }

  /** 档位名称 */
  private optionLabel(m: number): string {
    if (m === 1) {
      return '最新';
    }
    if (m === 2) {
      return '精选';
    }
    return '热门';
  }

  build() {
    Column({ space: Spacing.md }) {
      Text('吧主页默认进入界面')
        .fontSize(fs(17, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
        .textAlign(TextAlign.Center)
        .width('100%')

      Text('选择进入任意吧主页时默认显示的排序')
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textTertiary(this.isDark))
        .textAlign(TextAlign.Center)
        .width('100%')

      ForEach(FORUM_SORT_OPTIONS, (m: number) => {
        Row({ space: Spacing.sm }) {
          Column({ space: 2 }) {
            Text(this.optionLabel(m))
              .fontSize(fs(15, this.fontScale))
              .fontWeight(this.mode === m ? FontWeight.Bold : FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.isDark))
            Text(this.optionNote(m))
              .fontSize(fs(11, this.fontScale))
              .fontColor(Theme.textTertiary(this.isDark))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          if (this.mode === m) {
            SymbolGlyph($r('sys.symbol.checkmark_circle'))
              .fontColor([Theme.brand()])
              .fontSize(fs(20, this.fontScale))
          }
        }
        .width('100%')
        .padding({ left: Spacing.md, right: Spacing.md, top: Spacing.md, bottom: Spacing.md })
        .backgroundColor(this.mode === m ? (this.isDark ? '#333173FF' : '#1A3173FF') : Color.Transparent)
        .borderRadius(Radius.md * this.cardRadiusScale)
        .onClick(() => { this.onPick(m); })
      }, (m: number) => `forum_sort_${m}`)

      Button() {
        Text('取消')
          .fontSize(fs(15, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
      }
      .width('100%')
      .height(44)
      .systemMaterial(ImmMaterial.cardAction())
      .backgroundColor(this.isDark ? '#B31B1E24' : '#B3FFFFFF')
      .borderRadius(Radius.full)
      .shadow({ radius: 10, color: this.isDark ? '#4D000000' : '#1F101824', offsetY: 3 })
      .onClick(() => { this.onDismiss(); })
    }
    .width('100%')
    .padding(Spacing.lg)
  }
}

@Entry
@Component
struct LayoutSettingsPage {
  @StorageLink('cardRadiusScale') cardRadiusScale: number = DEFAULT_CARD_RADIUS_SCALE;
  @StorageLink('dockOrder') dockOrderStr: string = '0,1,2,3,4';
  @StorageLink('dockHidden') dockHiddenStr: string = '';
  @StorageLink('pageMargin') pageMargin: number = DEFAULT_PAGE_MARGIN;
  @StorageLink('tabAnimEnabled') tabAnimEnabled: boolean = true;
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;
  @State isDark: boolean = false;
  @State defaultTab: number = 0;
  /** 顶栏模糊三项本地档位（拖动时即时预览；松手 / 点击才落盘并广播全局） */
  @State topBlur: number = TopBarFx.DEFAULT_BLUR;
  @State topSolid: number = TopBarFx.DEFAULT_SOLID;
  @State topFade: number = TopBarFx.DEFAULT_FADE;
  /** 「卡片圆角」缩放本地档位（拖动实时预览；松手 / 点击才落盘） */
  @State cardRadiusPreview: number = DEFAULT_CARD_RADIUS_SCALE;
  /** 「最近进入」吧头像大小（vp，真源 AppStorage；拖动实时预览，松手落盘） */
  @StorageLink('recentAvatarSize') recentAvatarSize: number = DEFAULT_RECENT_AVATAR_SIZE;
  /** API26+ 沉浸光感能力：true 时顶栏走官方 title 槽位，否则回退自绘玻璃 TopBar */
  @State materialSupported: boolean = false;
  /** 「列数调整」档位（0/1/2，与 UsageHabitsManager 共用真源；写入走 setColumnMode 落盘 + 广播） */
  @StorageLink('columnMode') columnMode: number = 0;
  /** 「吧主页默认进入界面」档位（0 = 热门 / 1 = 最新 / 2 = 精选；写入走 setForumDefaultSort 落盘） */
  @StorageLink('forumDefaultSort') forumDefaultSort: number = 0;
  @StorageLink('floatingPageBars') floatingPageBars: boolean = true;
  @StorageLink('bottomBarBackdrop') bottomBarBackdrop: boolean = false;
  /** 「关闭自动旋转」开关（仅阔直屏直板显示；true = 固定竖屏） */
  @StorageLink('autoRotateOff') autoRotateOff: boolean = false;

  aboutToAppear(): void {
    MaterialManager.init();
    this.isDark = isDarkMode();
    this.materialSupported = MaterialManager.isSupported() && MaterialManager.getApiLevel() >= 26;
    this.defaultTab = UsageHabitsManager.getInstance().getDefaultTab();
    this.topBlur = UsageHabitsManager.getInstance().getTopBarBlur();
    this.topSolid = UsageHabitsManager.getInstance().getTopBarSolid();
    this.topFade = UsageHabitsManager.getInstance().getTopBarFade();
    this.cardRadiusPreview = UsageHabitsManager.getInstance().getCardRadiusScale();
  }

  /** 「列数调整」选定档位：走 manager 写 AppStorage + 落盘 + 广播，随后关闭弹窗（显示值经 @StorageLink 自动同步） */
  private pickColumnMode(mode: number): void {
    UsageHabitsManager.getInstance().setColumnMode(mode).catch(() => {
    });
    this.columnModeController.close();
  }

  /** 「吧主页默认进入界面」选定档位：走 manager 写 AppStorage + 落盘，随后关闭弹窗 */
  private pickForumDefaultSort(mode: number): void {
    UsageHabitsManager.getInstance().setForumDefaultSort(mode).catch(() => {
    });
    this.forumSortController.close();
  }

  /**
   * 弹窗宽度（vp 数值）—— 工程同款：`max(200, min(400, 屏宽 − 48))`。
   * 必须给数值：`CustomDialogControllerOptions.width` 类型是 `Dimension`，不接受 'calc(...)' 字符串。
   */
  private dialogCardWidth(): number {
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      const widthVp: number = info.width / info.densityPixels;
      return Math.max(200, Math.min(400, widthVp - 48));
    } catch (e) {
      return 312;
    }
  }

  /** 吧主页默认排序当前档位显示文案（设置行右侧） */
  private forumSortLabel(): string {
    if (this.forumDefaultSort === 1) {
      return '最新';
    }
    if (this.forumDefaultSort === 2) {
      return '精选';
    }
    return '热门';
  }

  /** 「列数调整」三选一弹窗控制器（几何与工程既有 CustomDialog 同源：宽 dialogCardWidth()、圆角 32、底部锚点 dy -110） */
  private columnModeController: CustomDialogController = new CustomDialogController({
    builder: ColumnModeDialog({
      isDark: $isDark,
      fontScale: $fontScale,
      mode: $columnMode,
      onPick: (m: number) => { this.pickColumnMode(m); },
      onDismiss: () => { this.columnModeController.close(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -110 },
    maskColor: '#06000000',
    cornerRadius: 32,
    width: this.dialogCardWidth(),
    customStyle: false,
    systemMaterial: ImmMaterial.dialog(),
    openAnimation: { duration: 220, curve: Curve.EaseOut },
    closeAnimation: { duration: 200, curve: Curve.EaseInOut },
    onWillDismiss: () => { }
  });

  /** 「吧主页默认进入界面」三选一弹窗控制器（几何与列数调整弹窗同源） */
  private forumSortController: CustomDialogController = new CustomDialogController({
    builder: ForumDefaultSortDialog({
      isDark: $isDark,
      fontScale: $fontScale,
      mode: $forumDefaultSort,
      onPick: (m: number) => { this.pickForumDefaultSort(m); },
      onDismiss: () => { this.forumSortController.close(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -110 },
    maskColor: '#06000000',
    cornerRadius: 32,
    width: this.dialogCardWidth(),
    customStyle: false,
    systemMaterial: ImmMaterial.dialog(),
    openAnimation: { duration: 220, curve: Curve.EaseOut },
    closeAnimation: { duration: 200, curve: Curve.EaseInOut },
    onWillDismiss: () => { }
  });

  onDarkTick(): void {
    this.isDark = isDarkMode();
  }

  /** 解析当前 Dock 顺序为合法的 TabIndex 数组（缺项补齐，保证 5 项） */
  private dockOrderArr(): number[] {
    const parts: string[] = this.dockOrderStr.split(',');
    const out: number[] = [];
    for (let i = 0; i < parts.length; i++) {
      const n: number = Number.parseInt(parts[i].trim(), 10);
      if (!Number.isNaN(n) && n >= 0 && n <= 4 && out.indexOf(n) < 0) {
        out.push(n);
      }
    }
    for (let k = 0; k <= 4; k++) {
      if (out.indexOf(k) < 0) {
        out.push(k);
      }
    }
    return out;
  }

  private dockHiddenArr(): number[] {
    const parts: string[] = this.dockHiddenStr.split(',');
    const out: number[] = [];
    for (let i = 0; i < parts.length; i++) {
      const n: number = Number.parseInt(parts[i].trim(), 10);
      if (!Number.isNaN(n) && n >= 0 && n <= 4 && out.indexOf(n) < 0) {
        out.push(n);
      }
    }
    return out;
  }

  private isTabHidden(index: number): boolean {
    return this.dockHiddenArr().indexOf(index) >= 0;
  }

  private dockMeta(index: number): DockTabMeta {
    for (let i = 0; i < DOCK_TABS.length; i++) {
      if (DOCK_TABS[i].index === index) {
        return DOCK_TABS[i];
      }
    }
    return DOCK_TABS[0];
  }

  private defaultTabOptions(): number[] {
    return [0, 1, 2, 3, 4];
  }

  /** 拖拽排序：把 from 项移动到 to 位置并持久化 */
  private reorderDock(from: number, to: number): void {
    const arr: number[] = this.dockOrderArr();
    if (from < 0 || from >= arr.length) {
      return;
    }
    let insert: number = to;
    if (insert < 0) {
      insert = 0;
    }
    if (insert > arr.length) {
      insert = arr.length;
    }
    if (from < insert) {
      insert = insert - 1;
    }
    const moved: number = arr.splice(from, 1)[0];
    arr.splice(insert, 0, moved);
    UsageHabitsManager.getInstance().setDockOrder(arr.join(','));
  }

  /** 显示/隐藏某个 Dock 项（至少保留一项可见） */
  private toggleTabHidden(idx: number, hide: boolean): void {
    const hidden: number[] = this.dockHiddenArr();
    const pos: number = hidden.indexOf(idx);
    if (hide) {
      if (pos >= 0) {
        return;
      }
      if (hidden.length >= 4) {
        return; // 已隐藏 4 项，禁止再隐藏最后一项
      }
      hidden.push(idx);
    } else {
      if (pos >= 0) {
        hidden.splice(pos, 1);
      }
    }
    UsageHabitsManager.getInstance().setDockHidden(hidden.join(','));
  }

  private resetDock(): void {
    UsageHabitsManager.getInstance().setDockOrder('0,1,2,3,4');
    UsageHabitsManager.getInstance().setDockHidden('');
  }

  private selectDefaultTab(tab: number): void {
    this.defaultTab = tab;
    UsageHabitsManager.getInstance().setDefaultTab(tab);
  }

  /** 边距变化：向 manager 写入（内部取整与 clamp），@StorageLink 触发全局刷新 */
  private onMarginChange(value: number): void {
    UsageHabitsManager.getInstance().setPageMargin(Math.round(value));
  }

  private isSliderSettled(mode: SliderChangeMode): boolean {
    return mode === SliderChangeMode.End || mode === SliderChangeMode.Click;
  }

  /** 模糊强度：拖动时只更新本地档位（即时预览），松手后落盘并广播全局重绘 */
  private onTopBlurChange(value: number, mode: SliderChangeMode): void {
    this.topBlur = Math.round(value);
    if (this.isSliderSettled(mode)) {
      this.applyTopBarFx();
    }
  }

  /** 全模糊段：不得越过渐退段起点（保留 0.02 间隔） */
  private onTopSolidChange(value: number, mode: SliderChangeMode): void {
    this.topSolid = Math.min(Math.round(value * 100) / 100, Math.max(0, this.topFade - 0.02));
    if (this.isSliderSettled(mode)) {
      this.applyTopBarFx();
    }
  }

  /** 渐退段为 0 时关闭渐变模糊，其他档位保留与实心段的间隔。 */
  private onTopFadeChange(value: number, mode: SliderChangeMode): void {
    const fade: number = Math.round(value * 100) / 100;
    this.topFade = fade === 0 ? 0 : Math.max(fade, this.topSolid + 0.02);
    if (this.isSliderSettled(mode)) {
      if (this.topFade === 0) {
        this.topSolid = 0;
      }
      this.applyTopBarFx();
    }
  }

  private applyTopBarFx(): void {
    UsageHabitsManager.getInstance().setTopBarFx(this.topBlur, this.topSolid, this.topFade).catch(() => {
    });
  }

  private resetTopBarFx(): void {
    this.topBlur = TopBarFx.DEFAULT_BLUR;
    this.topSolid = TopBarFx.DEFAULT_SOLID;
    this.topFade = TopBarFx.DEFAULT_FADE;
    UsageHabitsManager.getInstance().resetTopBarFx().catch(() => {
    });
  }

  /** 卡片圆角：拖动实时预览（仅写内存，全站卡片立即重绘），松手 / 点击才落盘 */
  private onCardRadiusChange(value: number, mode: SliderChangeMode): void {
    const v: number = Math.max(0, Math.min(2, Math.round(value * 20) / 20));
    this.cardRadiusPreview = v;
    AppStorage.setOrCreate('cardRadiusScale', v);
    if (this.isSliderSettled(mode)) {
      UsageHabitsManager.getInstance().setCardRadiusScale(v).catch(() => {
      });
    }
  }

  private resetCardRadiusScale(): void {
    this.cardRadiusPreview = DEFAULT_CARD_RADIUS_SCALE;
    UsageHabitsManager.getInstance().resetCardRadiusScale().catch(() => {
    });
  }

  /** 「最近进入」吧头像大小：拖动实时预览（仅写内存，进吧页立即重绘），松手 / 点击才落盘 */
  private onRecentAvatarChange(value: number, mode: SliderChangeMode): void {
    const v: number = Math.max(0, Math.min(72, Math.round(value / 2) * 2));
    this.recentAvatarSize = v;
    AppStorage.setOrCreate('recentAvatarSize', v);
    if (this.isSliderSettled(mode)) {
      UsageHabitsManager.getInstance().setRecentAvatarSize(v).catch(() => {
      });
    }
  }

  private resetRecentAvatarSize(): void {
    UsageHabitsManager.getInstance().resetRecentAvatarSize().catch(() => {
    });
  }

  /** 官方材质标题栏（API26+）：返回钮 + 标题，玻璃用 ImmMaterial.seg(false) 吃系统材质（自带清晰边缘） */
  @Builder
  LayoutTitleBar() {
    Row({ space: Spacing.sm }) {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontColor([$r('sys.color.icon_primary')])
          .fontSize(fs(22, this.fontScale))
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .systemMaterial(ImmMaterial.seg(false))
      .borderRadius(Radius.full)
      .accessibilityText('返回')
      .onClick(() => { this.getUIContext().getRouter().back(); })

      Text('界面布局')
        .fontSize(fs(18, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
  }

  /** 兜底路径专用（非 API26 / 关闭官方槽位）：页面主体悬浮自绘玻璃顶栏 */
  @Builder
  TopBar() {
    Row({ space: Spacing.sm }) {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontColor([$r('sys.color.icon_primary')])
          .fontSize(fs(22, this.fontScale))
      }
      .width(44)
      .height(44)
      .backgroundColor(Theme.manualGlass(this.isDark))
      .border({ width: 0.5, color: Theme.manualGlassBorder() })
      .shadow(Theme.glassShadowStyle())
      .backgroundEffect(ImmBlur.control())
      .systemMaterial(ImmMaterial.control())
      .borderRadius(Radius.full)
      .accessibilityText('返回')
      .onClick(() => { this.getUIContext().getRouter().back(); })

      Text('界面布局')
        .fontSize(fs(18, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
    .backgroundColor(Color.Transparent)
    .zIndex(14)
  }

  @Builder
  SectionTitle(title: string, desc: string) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(fs(15, this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.isDark))
      Text(desc)
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: Spacing.md })
  }

  @Builder
  MarginCard() {
    Column({ space: Spacing.sm }) {
      Row() {
        Text('左右留白')
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .layoutWeight(1)
        Text(`${Math.round(this.pageMargin)} vp`)
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.brand())
      }
      .width('100%')

      Slider({ value: this.pageMargin, min: 0, max: 24, step: 1 })
        .width('100%')
        .onChange((value: number) => { this.onMarginChange(value); })

      Text(`0 表示内容铺满屏幕边缘。数值越大，两侧留白越宽（默认 ${DEFAULT_PAGE_MARGIN} vp）。`)
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
    }
    .width('100%')
    .padding(Spacing.lg)
    .borderRadius(Radius.lg * this.cardRadiusScale)
    .backgroundColor(Theme.bgCard(this.isDark))
  }

  /** 拖拽时跟随手指的预览卡片 */
  @Builder
  DockDragPreview(idx: number) {
    Row({ space: Spacing.sm }) {
      Text(this.dockMeta(idx).icon)
        .fontSize(18)
        .fontColor(Theme.textPrimary(this.isDark))
        .width(26)
        .textAlign(TextAlign.Center)
      Text(this.dockMeta(idx).label)
        .fontSize(fs(14, this.fontScale))
        .fontColor(Theme.textPrimary(this.isDark))
    }
    .width(180)
    .height(48)
    .padding({ left: Spacing.md, right: Spacing.md })
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.md * this.cardRadiusScale)
    .opacity(0.92)
  }

  @Builder
  DockOrderRow(idx: number) {
    Row({ space: Spacing.sm }) {
      Text('≡')
        .fontSize(16)
        .fontColor(Theme.textSecondary(this.isDark))
        .width(18)
        .textAlign(TextAlign.Center)
      Text(this.dockMeta(idx).icon)
        .fontSize(18)
        .fontColor(Theme.textPrimary(this.isDark))
        .width(26)
        .textAlign(TextAlign.Center)
      Text(this.dockMeta(idx).label)
        .fontSize(fs(14, this.fontScale))
        .fontColor(Theme.textPrimary(this.isDark))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: !this.isTabHidden(idx) })
        .onChange((isOn: boolean) => { this.toggleTabHidden(idx, !isOn); })
    }
    .width('100%')
    .height(52)
    .padding({ left: Spacing.sm, right: Spacing.sm })
    .borderRadius(Radius.md * this.cardRadiusScale)
    .backgroundColor(Theme.bgSurface(this.isDark))
  }

  @Builder
  DockOrderCard() {
    Column({ space: Spacing.xs }) {
      List({ space: Spacing.xs }) {
        ForEach(this.dockOrderArr(), (idx: number, pos: number) => {
          ListItem() {
            this.DockOrderRow(idx)
          }
          .width('100%')
        }, (idx: number) => 'dock-' + idx)
      }
      .width('100%')
      .height(this.dockOrderArr().length * 56)
      .editMode(true)
      .onItemDragStart((event: ItemDragInfo, itemIndex: number) => {
        return this.DockDragPreview(this.dockOrderArr()[itemIndex]);
      })
      .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
        if (isSuccess) {
          this.reorderDock(itemIndex, insertIndex);
        }
      })

      Row() {
        Blank()
        Text('恢复默认顺序')
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.brand())
          .onClick(() => { this.resetDock(); })
      }
      .width('100%')
      .margin({ top: Spacing.sm })

      Text('长按并拖动可调整顺序；右侧开关控制是否在底栏显示（至少保留一项）。')
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
        .margin({ top: Spacing.xs })
    }
    .width('100%')
    .padding(Spacing.lg)
    .borderRadius(Radius.lg * this.cardRadiusScale)
    .backgroundColor(Theme.bgCard(this.isDark))
  }

  @Builder
  DefaultTabCard() {
    Column({ space: Spacing.sm }) {
      Row({ space: Spacing.sm }) {
        ForEach(this.defaultTabOptions(), (idx: number) => {
          Text(this.dockMeta(idx).label)
            .fontSize(fs(14, this.fontScale))
            .fontColor(this.defaultTab === idx ? Color.White : Theme.textSecondary(this.isDark))
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(40)
            .borderRadius(Radius.md * this.cardRadiusScale)
            .backgroundColor(this.defaultTab === idx ? Theme.brand() : Theme.bgSurface(this.isDark))
            .onClick(() => { this.selectDefaultTab(idx); })
        }, (idx: number) => 'deftab-' + idx)
      }
      .width('100%')

      Text('下次启动应用后，将默认停留在所选界面（下一次冷启动生效）。')
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
    }
    .width('100%')
    .padding(Spacing.lg)
    .borderRadius(Radius.lg * this.cardRadiusScale)
    .backgroundColor(Theme.bgCard(this.isDark))
  }

  @Builder
  TabAnimCard() {
    Row() {
      Column({ space: 2 }) {
        Text('切页平移动画')
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
        Text('关闭后，切换五个主界面时不播放左右平移过渡')
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.tabAnimEnabled })
        .onChange((isOn: boolean) => {
          UsageHabitsManager.getInstance().setTabAnimationEnabled(isOn);
        })
    }
    .width('100%')
    .padding(Spacing.lg)
    .borderRadius(Radius.lg * this.cardRadiusScale)
    .backgroundColor(Theme.bgCard(this.isDark))
  }

  /** 顶栏渐变模糊三项可调：模糊强度 / 全模糊段高度 / 渐退段高度（拖动即在本页顶栏预览） */
  @Builder
  TopBarFxCard() {
    Column({ space: Spacing.sm }) {
      Row() {
        Text('模糊强度')
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .layoutWeight(1)
        Text(`${this.topBlur} vp`)
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.brand())
      }
      .width('100%')

      Slider({ value: this.topBlur, min: 0, max: 60, step: 1 })
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => { this.onTopBlurChange(value, mode); })

      Row() {
        Text('实心模糊段')
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .layoutWeight(1)
        Text(`${Math.round(this.topSolid * 100)}%`)
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.brand())
      }
      .width('100%')
      .margin({ top: Spacing.sm })

      Slider({ value: this.topSolid, min: 0, max: 0.9, step: 0.01 })
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => { this.onTopSolidChange(value, mode); })

      Row() {
        Text('渐退段')
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .layoutWeight(1)
        Text(`${Math.round(this.topFade * 100)}%`)
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.brand())
      }
      .width('100%')
      .margin({ top: Spacing.sm })

      Slider({ value: this.topFade, min: 0, max: 1, step: 0.01 })
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => { this.onTopFadeChange(value, mode); })

      Row() {
        Blank()
        Text('恢复默认')
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.brand())
          .onClick(() => { this.resetTopBarFx(); })
      }
      .width('100%')
      .margin({ top: Spacing.sm })

      Text('拖动滑杆可在本页顶部预览效果。模糊强度为 0 时关闭模糊。渐退段为 0 时，实心段一并归零。玻璃质感层固定叠加。')
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
        .margin({ top: Spacing.xs })
    }
    .width('100%')
    .padding(Spacing.lg)
    .borderRadius(Radius.lg * this.cardRadiusScale)
    .backgroundColor(Theme.bgCard(this.isDark))
  }

  /** 「卡片圆角」整体缩放：拖动即全站实时预览，松手落盘（本页卡片即为预览样本） */
  @Builder
  CardRadiusCard() {
    Column({ space: Spacing.sm }) {
      Row() {
        Text('圆角程度')
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .layoutWeight(1)
        Text(`${Math.round(this.cardRadiusPreview * 100)}%`)
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.brand())
      }
      .width('100%')

      Slider({ value: this.cardRadiusPreview, min: 0, max: 2, step: 0.05 })
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => { this.onCardRadiusChange(value, mode); })

      Row() {
        Blank()
        Text('恢复默认')
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.brand())
          .onClick(() => { this.resetCardRadiusScale(); })
      }
      .width('100%')
      .margin({ top: Spacing.sm })

      Text(`全站卡片（帖子卡、楼层卡、弹层与底部面板）的圆角缩放。默认 ${Math.round(DEFAULT_CARD_RADIUS_SCALE * 100)}%，0% 为直角。头像、徽章与底部栏不受影响。`)
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
        .margin({ top: Spacing.xs })
    }
    .width('100%')
    .padding(Spacing.lg)
    .borderRadius(Radius.lg * this.cardRadiusScale)
    .backgroundColor(Theme.bgCard(this.isDark))
  }

  /** 「最近进入」吧头像大小：拖动即进吧页实时预览，松手落盘 */
  @Builder
  RecentAvatarCard() {
    Column({ space: Spacing.sm }) {
      Row() {
        Text('头像大小')
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .layoutWeight(1)
        Text(`${this.recentAvatarSize} vp`)
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.brand())
      }
      .width('100%')

      Slider({ value: this.recentAvatarSize, min: 0, max: 72, step: 2 })
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => { this.onRecentAvatarChange(value, mode); })

      Row() {
        Blank()
        Text('恢复默认')
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.brand())
          .onClick(() => { this.resetRecentAvatarSize(); })
      }
      .width('100%')
      .margin({ top: Spacing.sm })

      Text(`进吧页「最近进入」的吧头像大小，默认 ${DEFAULT_RECENT_AVATAR_SIZE} vp。设为 0 时只显示吧名。`)
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
        .margin({ top: Spacing.xs })
    }
    .width('100%')
    .padding(Spacing.lg)
    .borderRadius(Radius.lg * this.cardRadiusScale)
    .backgroundColor(Theme.bgCard(this.isDark))
  }

  /** 列数调整（自「个性化」页并入）：大屏形态列表列数三选一，点开弹窗 */
  @Builder
  ColumnModeCard() {
    Row() {
      Column({ space: 2 }) {
        Text('列数调整')
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
        Text('平板 / 阔直屏 / 折叠屏展开的列表列数')
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(columnModeLabel(this.columnMode))
        .fontSize(fs(13, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontColor([$r('sys.color.icon_secondary')])
        .fontSize(fs(16, this.fontScale))
        .margin({ left: Spacing.xs })
    }
    .width('100%')
    .padding(Spacing.lg)
    .borderRadius(Radius.lg * this.cardRadiusScale)
    .backgroundColor(Theme.bgCard(this.isDark))
    .onClick(() => { this.columnModeController.open(); })
  }

  /** 吧主页默认排序（自「使用习惯」页并入）：进入吧主页时默认显示的排序 */
  @Builder
  ForumSortCard() {
    Row() {
      Column({ space: 2 }) {
        Text('吧主页默认排序')
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
        Text('选择进入吧主页时默认显示的排序')
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.forumSortLabel())
        .fontSize(fs(13, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontColor([$r('sys.color.icon_secondary')])
        .fontSize(fs(16, this.fontScale))
        .margin({ left: Spacing.xs })
    }
    .width('100%')
    .padding(Spacing.lg)
    .borderRadius(Radius.lg * this.cardRadiusScale)
    .backgroundColor(Theme.bgCard(this.isDark))
    .onClick(() => { this.forumSortController.open(); })
  }

  /** 关闭自动旋转（自「使用习惯」页并入，仅阔直屏直板显示）：开启后固定竖屏 */
  @Builder
  AutoRotateCard() {
    Row() {
      Column({ space: 2 }) {
        Text('关闭自动旋转')
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
        Text('开启后固定竖屏，不再自动转为横屏')
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.autoRotateOff })
        .onChange((isOn: boolean) => {
          UsageHabitsManager.getInstance().setAutoRotateOff(isOn);
        })
    }
    .width('100%')
    .padding(Spacing.lg)
    .borderRadius(Radius.lg * this.cardRadiusScale)
    .backgroundColor(Theme.bgCard(this.isDark))
  }

  /** 页面主体（内容 + 遮罩 + 兜底顶栏），官方标题栏路径下不再叠自绘顶栏 */
  @Builder
  FloatingPageBarsCard() {
    Row() {
      Text('悬浮顶栏和底栏')
        .fontSize(fs(14, this.fontScale))
        .fontColor(Theme.textPrimary(this.isDark))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.floatingPageBars })
        .id('floating_page_bars_toggle')
        .accessibilityText('悬浮顶栏和底栏')
        .onChange((isOn: boolean) => {
          UsageHabitsManager.getInstance().setFloatingPageBars(isOn);
        })
    }
    .width('100%')
    .padding(Spacing.lg)
    .borderRadius(Radius.lg * this.cardRadiusScale)
    .backgroundColor(Theme.bgCard(this.isDark))
  }

  @Builder
  LayoutContent() {
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Column({ space: Spacing.md }) {
          // 预留顶栏高度的初始间距
          Column()
            .width('100%')
            .height(90)

          this.SectionTitle('页面边距', '调整页面内容与屏幕边缘的距离')
          this.MarginCard()

          this.SectionTitle('卡片圆角', '全站卡片圆角的整体缩放')
          this.CardRadiusCard()

          this.SectionTitle('列数调整', '大屏设备列表展示的列数')
          this.ColumnModeCard()

          this.SectionTitle('最近进入吧头像', '进吧页「最近进入」头像的大小')
          this.RecentAvatarCard()

          this.SectionTitle('Dock 栏', '拖动排序；开关控制底栏是否显示该入口')
          this.DockOrderCard()

          this.SectionTitle('默认显示界面', '选择进入应用后默认停留的界面')
          this.DefaultTabCard()

          this.SectionTitle('吧主页默认排序', '选择进入吧主页时默认显示的排序')
          this.ForumSortCard()

          this.SectionTitle('吧页与帖子栏样式', '关闭后，顶栏和底栏固定在内容区外')
          this.FloatingPageBarsCard()

          this.SectionTitle('底栏周围效果', '开启后，悬浮底栏周围的内容会渐变淡化并模糊')
          Row() {
            Text('渐变和模糊')
              .fontSize(fs(14, this.fontScale))
              .fontColor(Theme.textPrimary(this.isDark))
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.bottomBarBackdrop })
              .id('bottom_bar_backdrop_toggle')
              .accessibilityText('底栏周围渐变和模糊')
              .onChange((isOn: boolean) => {
                UsageHabitsManager.getInstance().setBottomBarBackdrop(isOn);
              })
          }
          .width('100%')
          .padding(Spacing.lg)
          .borderRadius(Radius.lg * this.cardRadiusScale)
          .backgroundColor(Theme.bgCard(this.isDark))

          this.SectionTitle('切页动画', '主界面切换时的过渡效果')
          this.TabAnimCard()

          this.SectionTitle('顶栏模糊', '内容滚到顶部时的渐变模糊观感')
          this.TopBarFxCard()

          if (isWideBarFlatDevice()) {
            this.SectionTitle('屏幕旋转', '阔直屏直板的横竖屏控制')
            this.AutoRotateCard()
          }

          Row().height(40)
        }
        .width('100%')
        // 实时预览：本页内容横向留白同样跟随 pageMargin
        .padding({ left: this.pageMargin, right: this.pageMargin, bottom: 40 })
      }
      .scrollBar(BarState.Off)
      .scrollable(ScrollDirection.Vertical)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .layoutWeight(1)
      .clip(false)
      .align(Alignment.TopStart)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .linearGradientBlur(this.topFade === 0 ? 0 : this.topBlur, {
        fractionStops: [[1.0, 0.0], [1.0, this.topFade === 0 ? 0 : this.topSolid], [0.0, Math.max(0.02, this.topFade)], [0.0, 1.0]],
        direction: GradientDirection.Bottom
      })
      .overlay(() => { TopGlassVeil() })

      // 官方 title 槽位路径下已在槽位里（LayoutTitleBar），不再叠一层
      if (!(LAYOUT_OFFICIAL_TITLE_BAR && this.materialSupported)) {
        this.TopBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  build() {
    if (LAYOUT_OFFICIAL_TITLE_BAR && this.materialSupported) {
      // 官方槽位路径：返回钮 + 标题搬进 Navigation title 槽位，吃系统真材质（边缘清晰）
      Navigation() {
        this.LayoutContent()
      }
      .title({ builder: this.LayoutTitleBar(), height: LAYOUT_TITLE_BAR_HEIGHT },
        { barStyle: BarStyle.STACK, backgroundColor: Color.Transparent })
      .mode(NavigationMode.Stack)
      .hideTitleBar(false)
      .hideBackButton(true)
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg(this.isDark))
      .clip(false)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    } else {
      this.LayoutContent()
    }
  }
}
