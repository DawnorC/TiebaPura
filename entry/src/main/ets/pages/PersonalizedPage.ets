/*
 * TiebaPura - HarmonyOS 原生 ArkTS 实现的第三方百度贴吧客户端
 * Copyright (C) 2026 a307608689-afk
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import {
  Theme, Spacing, Radius, isDarkMode, setDarkMode as applyAppDarkMode, syncDarkFromConfig,
  resetConfigurationToFollowSystem, ImmBlur, ImmMaterial, MaterialManager, fs, tabletTopFadeStop,
  DEFAULT_PAGE_MARGIN, DEFAULT_CARD_RADIUS_SCALE
} from '../common/Theme';
import { UsageHabitsManager } from '../service/UsageHabitsManager';
import { BRAND_BLUE } from '../common/Constants';

import { TopBarFx } from '../components/TopBarFx';
import { TopGlassVeil } from '../components/TopGlassVeil';

@Entry
@Component
struct PersonalizedPage {
  @StorageLink('cardRadiusScale') cardRadiusScale: number = DEFAULT_CARD_RADIUS_SCALE;
  @StorageLink('topBarFxTick') tbxTick: number = 0;
  /** 页面边距（左右留白，实时同步；16=默认，0=贴边） */
  @StorageLink('pageMargin') pageMargin: number = DEFAULT_PAGE_MARGIN;
  @StorageLink('fontScale') fontScale: number = 1.0;
  /** 页面可见时自增，强制组件重建使字号实时生效 */
  @State fontSizeTick: number = 0;
  /** 「深色模式」手动开关（仅当 followSystem=false 时生效；持久化） */
  @StorageLink('appDarkMode') darkMode: boolean = false;
  /** 「跟随系统深色模式」开关（默认 true；持久化） */
  @StorageLink('appFollowSystemDark') followSystem: boolean = true;
  /** darkTick 自增：本页或其它入口（含系统 onConfigurationUpdate）触发后翻 this.isDark，与首页/MineTab 同链路 */
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;

  onPageShow(): void {
    this.fontSizeTick++;
  }
  @State isDark: boolean = isDarkMode();
  /**
   * 「帖子沉浸式阅读」开关（默认关）：详情页 / 楼中楼页向下滑动自动收起顶栏与底栏，向上滑动或回到顶部恢复。
   * 真源与 UsageHabitsManager 共用（写走 setImmersiveReading：AppStorage + 落盘），页面开关只作显示。
   */
  @StorageLink('immersiveReading') immersiveReading: boolean = false;
  /**
   * 「沉浸式阅读补全」开关（默认关）：独立开关项，不与「帖子沉浸式阅读」联挂。
   * 开启后首页 / 收藏页 / 收藏夹二级页 / 吧主页向下滑动自动收起顶栏与底栏。
   * 真源与 UsageHabitsManager 共用（写走 setImmersiveReadExtra：AppStorage + 落盘），页面开关只作显示。
   */
  @StorageLink('immersiveReadExtra') immersiveReadExtra: boolean = false;
  /** 「仅推荐关注的吧」开关（默认关）：首页推荐仅显示关注吧的帖子（真源与 UsageHabitsManager 共用） */
  @StorageLink('homeOnlyFollow') onlyFollow: boolean = false;
  /** 「楼中楼回复字号」整体缩放比例（0.7~1.1，缺省 0.9；真源与 UsageHabitsManager 共用） */
  @StorageLink('subReplyScale') subReplyScale: number = 0.9;

  aboutToAppear(): void {
    MaterialManager.init();
    this.isDark = isDarkMode();
    // 兜底：若冷启动 Index.aboutToAppear 异常未初始化，这里也能补上（正常路径下已初始化）
    UsageHabitsManager.getInstance().init(this.getUIContext().getHostContext() as common.UIAbilityContext);
  }

  /** darkTick 递增（任意入口切换深色，包括系统 onConfigurationUpdate）→ 重读 isDarkMode() 翻本组件渲染色 */
  private onDarkTick(): void {
    this.isDark = isDarkMode();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 内容层：全屏沉浸滚动（参数同 Settings.ets /「我的」页范式）
      Scroll() {
        Column({ space: Spacing.sm }) {
          // 预留顶栏高度的初始间距
          Column()
            .width('100%')
            .height(90)
          // 字体大小条目
          Row({ space: Spacing.md }) {
            Stack() {
              Text('A')
                .fontSize(fs(15, this.fontScale))
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary(this.isDark))
            }
            .width(24)
            .height(24)
            .border({ width: 2, color: Theme.textPrimary(this.isDark), radius: 4 })
            .alignContent(Alignment.Center)

            Column({ space: 2 }) {
              Text('字体大小')
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.isDark))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: Spacing.xs })

            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontColor([$r('sys.color.icon_secondary')])
              .fontSize(fs(18, this.fontScale))
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.xl, bottom: Spacing.xl })
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg * this.cardRadiusScale)
          .margin({ top: Spacing.sm })
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/FontSizePage' }).catch(() => {});
          })

          // 楼中楼回复字号（整体缩小、可调：以楼层正文为基准的相对缩放）
          Column({ space: Spacing.sm }) {
            Row({ space: Spacing.md }) {
              Text('Aa')
                .fontSize(fs(20, this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.brand())
                .width(22)
                .textAlign(TextAlign.Center)
              Column({ space: 2 }) {
                Text('楼中楼回复字号')
                  .fontSize(fs(18, this.fontScale))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.textPrimary(this.isDark))
                Text('楼中楼回复整体相对楼层字号缩放')
                  .fontSize(fs(12, this.fontScale))
                  .fontColor(Theme.textSecondary(this.isDark))
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Text(`${Math.round(this.subReplyScale * 100)}%`)
                .fontSize(fs(14, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .width('100%')
            Slider({ value: Math.round(this.subReplyScale * 100), min: 70, max: 110, step: 5 })
              .selectedColor(BRAND_BLUE)
              .onChange((value: number, mode: SliderChangeMode) => {
                const s: number = value / 100;
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  UsageHabitsManager.getInstance().setSubReplyScale(s);
                } else {
                  AppStorage.setOrCreate('subReplyScale', s);
                }
              })
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.xl, bottom: Spacing.xl })
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg * this.cardRadiusScale)
          .margin({ top: Spacing.sm })

          // 深色模式（手动开关）：触动本开关即自动关闭「跟随系统」，使生效行为 = 本开关值
          Row({ space: Spacing.md }) {
            SymbolGlyph($r('sys.symbol.moon_fill'))
              .fontColor([Theme.textPrimary(this.isDark)])
              .fontSize(fs(22, this.fontScale))

            Column({ space: 2 }) {
              Text('深色模式')
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.isDark))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: Spacing.xs })

            // 只作显示：hitTestBehavior(None) 让触摸穿透到外层 Row 统一处理。这样系统切色时
            // EntryAbility 同步 appDarkMode 引发的编程性 isOn 变化不会触发 onChange 副作用，
            // 根治「跟随系统深色模式」被系统切色连带自动关闭的问题。
            Toggle({ type: ToggleType.Switch, isOn: this.darkMode })
              .selectedColor(BRAND_BLUE)
              .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.xl, bottom: Spacing.xl })
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg * this.cardRadiusScale)
          .margin({ top: Spacing.sm })
          .onClick(() => {
            // 用户意图只从点击进入，与原 onChange 逻辑完全等价：触动本开关即自动关闭「跟随系统」。
            // 1. 立即翻本组件 this.isDark（不依赖 setColorMode 重建，避免视觉卡顿）
            // 2. 写 manual + 关跟随系统
            // 3. Theme.setDarkMode 同步 _globalIsDark + 系统 Configuration + 状态栏
            // 4. darkTick++ 触发其它监听 darkTick 的页面（FavoriteTab/MineTab 等）翻 @State isDark
            const target: boolean = !UsageHabitsManager.getInstance().isDarkModeManual();
            this.isDark = target;
            UsageHabitsManager.getInstance().setFollowSystemDark(false);
            UsageHabitsManager.getInstance().setDarkModeManual(target);
            applyAppDarkMode(target);
            AppStorage.setOrCreate<number>('darkTick', (AppStorage.get<number>('darkTick') ?? 0) + 1);
          })

          // 跟随系统深色模式：开启时立即按系统当前态落地；关闭时不切色，由「深色模式」toggle 接管
          Row({ space: Spacing.md }) {
            SymbolGlyph($r('sys.symbol.brightness'))
              .fontColor([Theme.textPrimary(this.isDark)])
              .fontSize(fs(22, this.fontScale))

            Column({ space: 2 }) {
              Text('跟随系统深色模式')
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.isDark))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: Spacing.xs })

            // 只作显示：hitTestBehavior(None) + 外层 Row.onClick 统一承接用户意图，与上方「深色模式」
            // 开关同模式，防编程性 isOn 变化误触 onChange。
            Toggle({ type: ToggleType.Switch, isOn: this.followSystem })
              .selectedColor(BRAND_BLUE)
              .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.xl, bottom: Spacing.xl })
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg * this.cardRadiusScale)
          .margin({ top: Spacing.sm })
          .onClick(() => {
            const isOn: boolean = !UsageHabitsManager.getInstance().isFollowSystemDark();
            UsageHabitsManager.getInstance().setFollowSystemDark(isOn);
            if (isOn) {
              // 开启跟随系统：写 manual = 当前系统档 + 调 resetConfigurationToFollowSystem 把
              // Configuration 重置为 NOT_SET（系统档驱动） + 调 syncDarkFromConfig 同步 _globalIsDark。
              //
              // 关键：这里**不调 setColorMode(DARK/LIGHT)**，让 Application Configuration 保持
              // COLOR_MODE_NOT_SET（跟系统档），永不锁死。这样后续系统切深色/切浅色时，
              // Configuration 自动跟档，ForumsTitleBar / HomeTitleBar 的 systemMaterial 与
              // $r('sys.color.font_primary') 自动翻档。
              // 手动档（用户切色 / PersonalizedPage 深色模式开关）才会调 setColorMode 锁死。
              const ctx: common.UIAbilityContext =
                this.getUIContext().getHostContext() as common.UIAbilityContext;
              const sysDark: boolean =
                ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
              UsageHabitsManager.getInstance().setDarkModeManual(sysDark);
              resetConfigurationToFollowSystem();
              syncDarkFromConfig(sysDark);
              this.isDark = sysDark;
              AppStorage.setOrCreate<number>('darkTick', (AppStorage.get<number>('darkTick') ?? 0) + 1);
            } else {
              // 关闭：不切色——保持当前 dark 值，「深色模式」开关后续接管
              // 仍递增 darkTick 让其它页面同步（即便本组件未切色，也保证链路上各页 @State isDark 与开关一致）
              AppStorage.setOrCreate<number>('darkTick', (AppStorage.get<number>('darkTick') ?? 0) + 1);
            }
          })

          // 帖子沉浸式阅读：详情页向下滑动自动收起顶栏与底栏（向上滑动 / 回到顶部恢复）。
          // 与上方「跟随系统深色模式」开关同模式：Toggle 只作显示（hitTestBehavior(None)），
          // 用户意图一律由外层 Row.onClick 承接，防编程性 isOn 变化误触 onChange。
          Row({ space: Spacing.md }) {
            SymbolGlyph($r('sys.symbol.book_pages'))
              .fontColor([Theme.textPrimary(this.isDark)])
              .fontSize(fs(22, this.fontScale))

            Column({ space: 2 }) {
              Text('帖子沉浸式阅读')
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.isDark))
              Text('向下滑动时自动隐藏帖子顶栏与底栏，向上滑动或回到顶部重新出现')
                .fontSize(fs(12, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: Spacing.xs })

            Toggle({ type: ToggleType.Switch, isOn: this.immersiveReading })
              .selectedColor(BRAND_BLUE)
              .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.xl, bottom: Spacing.xl })
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg * this.cardRadiusScale)
          .margin({ top: Spacing.sm })
          .onClick(() => {
            const isOn: boolean = !UsageHabitsManager.getInstance().isImmersiveReading();
            UsageHabitsManager.getInstance().setImmersiveReading(isOn);
          })

          // 沉浸式阅读补全（独立开关项）：首页 / 收藏页 / 收藏夹二级页 / 吧主页同款自动收起。
          // 与上方开关同模式：Toggle 只作显示，意图由外层 Row.onClick 承接。
          Row({ space: Spacing.md }) {
            SymbolGlyph($r('sys.symbol.bookmark'))
              .fontColor([Theme.textPrimary(this.isDark)])
              .fontSize(fs(22, this.fontScale))

            Column({ space: 2 }) {
              Text('沉浸式阅读补全')
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.isDark))
              Text('让更多地方会自动隐藏顶栏和底栏')
                .fontSize(fs(12, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: Spacing.xs })

            Toggle({ type: ToggleType.Switch, isOn: this.immersiveReadExtra })
              .selectedColor(BRAND_BLUE)
              .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.xl, bottom: Spacing.xl })
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg * this.cardRadiusScale)
          .margin({ top: Spacing.sm })
          .onClick(() => {
            const isOn: boolean = !UsageHabitsManager.getInstance().isImmersiveReadExtra();
            UsageHabitsManager.getInstance().setImmersiveReadExtra(isOn);
          })

          // 仅推荐关注的吧：首页推荐仅显示关注吧的帖子（自「使用习惯」页并入）
          Row({ space: Spacing.md }) {
            SymbolGlyph($r('sys.symbol.hand'))
              .fontColor([Theme.brand()])
              .fontSize(fs(22, this.fontScale))

            Column({ space: 2 }) {
              Text('仅推荐关注的吧')
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.isDark))
              Text('首页推荐仅显示关注吧的帖子')
                .fontSize(fs(12, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.onlyFollow })
              .selectedColor(BRAND_BLUE)
              .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.xl, bottom: Spacing.xl })
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg * this.cardRadiusScale)
          .margin({ top: Spacing.sm })
          .onClick(() => {
            const isOn: boolean = !UsageHabitsManager.getInstance().isOnlyFollow();
            UsageHabitsManager.getInstance().setOnlyFollow(isOn);
          })
        }
        .width('100%')
        .padding({ left: this.pageMargin, right: this.pageMargin, bottom: Spacing.xl })
      }
      .scrollBar(BarState.Off)
      .scrollable(ScrollDirection.Vertical)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .layoutWeight(1)
      .clip(false)
      .align(Alignment.TopStart)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .linearGradientBlur(TopBarFx.blur(this.tbxTick), { fractionStops: [[1.0, 0.0], [1.0, TopBarFx.solid(this.tbxTick)], [0.0, TopBarFx.fade(this.tbxTick)], [0.0, 1.0]], direction: GradientDirection.Bottom })
      .overlay(() => { TopGlassVeil() })

      // 悬浮沉浸顶栏（透明底，内容可穿过；参数同 Settings.ets）
      this.TopBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 悬浮沉浸顶栏（透明底，内容可穿过；参数同 Settings.ets） */
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
      .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
      .systemMaterial(ImmMaterial.control())
      .borderRadius(Radius.full)
      .accessibilityText('返回')
      .onClick(() => { this.getUIContext().getRouter().back(); })

      Text('个性化')
        .fontSize(fs(18, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
    .backgroundColor(Color.Transparent)
    .zIndex(14)
  }
}
