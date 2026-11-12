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

import { deviceInfo } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AuthManager } from '../service/AuthManager';
import { UserStats, FollowItem, UserInfo } from '../model/DataModel';
import { CacheManager } from '../cache/CacheManager';
import { TiebaService } from '../service/TiebaService';
import { CACHE_KEY, CACHE_TTL } from '../common/Constants';
import {
  Theme, Spacing, Radius, fs, isDarkMode, setDarkMode, ImmBlur, ImmMaterial,
  isWideFormDevice as detectWideFormDevice,
  DEFAULT_PAGE_MARGIN, DEFAULT_CARD_RADIUS_SCALE
} from '../common/Theme';
import { UsageHabitsManager } from '../service/UsageHabitsManager';

import { TopBarFx } from '../components/TopBarFx';
import { TopGlassVeil } from '../components/TopGlassVeil';
/** 官方标题栏开关：true = 「我的」标题行（含右上角深色切换圆钮）走 Navigation title 槽位吃官方材质（§6.10 模板，与首页/进吧/收藏同机制）；
 *  false = 一键回退到页面主体悬浮自绘玻璃 TopBar（manualGlass + backgroundBlurStyle 真磨砂），旧 TopBar() 原样保留。 */
const MINE_OFFICIAL_TITLE_BAR: boolean = true;
/** 槽位高度 = 44(状态栏让位) + 44(按钮行高) + 10(底部呼吸)，与原悬浮 TopBar 的 padding 逐项一致；
 *  内容让位（List 首项占位 90）一行未改。 */
const MINE_TITLE_BAR_HEIGHT: number = 98;

/**
 * 「我的」主 Tab 页组件（从 Index.ets 内联 Builder MineContent 抽出）：
 * - 自含数据组件（2026-11-10 重构）：原「宿主为数据脑、@Link 显式注入」架构在真机冷启动
 *   恒显 0/--/--，逐层排查（绑定形式/切 Tab 重推/隐藏期赋值时序均证伪）后锁定真根因：
 *   统计行原经 this.StatItem(字符串参数, ...) @Builder 按值传参渲染——ArkUI 文档规则，
 *   按值传参的 @Builder 内容不随状态变量刷新（官方反例即 `${this.label}` 传参），
 *   首次求值（挂载初始 0/--/--）后永久冻结；而 builder 体内直读 this.xxx（如登录卡片、
 *   头像）与 LazyForEach 数据源（ForumsTab）均正常刷新，故仅统计行坏死。
 *   修复：统计行改组件渲染作用域内直绑求值（见 MineContent 内注释）。
 * - 架构同步改为与 HomeTab/ForumsTab 同款自含范式：本页自读 AuthManager 登录态、自载
 *   三项统计（关注吧快照/用户统计/关注用户数，缓存优先 SWR），经 tabLoginRefresh
 *   （登录/登出/换号广播）与 mineRefreshRequest（宿主 onPageShow / 切到本 Tab /
 *   profile 昵称校准）两个 tick 驱动刷新，宿主不再持有/下发任何我的页状态。
 * - 仅两类动作回宿主：切到收藏 Tab（openFavorite）、退出登录全局重置（onLogout）。
 * - 页面自身导航（我的主页/个人内容/关注列表/登录/设置）与文案换算逻辑内置。
 * - 深色模式经 AppStorage darkTick 事件同步（isDark 订阅模块全局，可自切）。
 */

@Component
export struct MineTab {
  @StorageLink('cardRadiusScale') cardRadiusScale: number = DEFAULT_CARD_RADIUS_SCALE;
  @StorageLink('topBarFxTick') tbxTick: number = 0;
  // 页面边距（左右留白，随设置页实时同步；16=默认，0=贴边）
  @StorageLink('pageMargin') pageMargin: number = DEFAULT_PAGE_MARGIN;
  /**
   * 顶部渐显带收窄（2026-09-13 用户反馈）：平板竖屏下原 15% 渐显覆盖到第一个卡片中部，
   * 要求「只覆盖顶部按钮与标题」→ 平板档覆盖高度 = 顶栏 98vp，手机维持原比例。
   */
  private readonly isWideFormDevice: boolean = detectWideFormDevice();
  /** 屏幕长边（vp）：竖屏视口高的稳定来源（旋转取长边，渐显比例不漂移） */
  @State fadeCoverVp: number = 0;
  @State loggedIn: boolean = false;
  @State userName: string = '';
  @State userAvatar: string = '';
  @State userStats: UserStats = { postCount: -1, agreeCount: -1 };
  @State statsLoading: boolean = false;
  @State statsError: boolean = false;
  @State followUserCount: number = -1;
  @State followUserLoading: boolean = false;
  @State follows: FollowItem[] = [];
  openFavorite: () => void = () => {};
  onLogout: () => void = () => {};
  // 登录/登出/换号全局广播（宿主 refreshLoginState 递增）：重读账号资料并重载三项统计
  @StorageLink('tabLoginRefresh') @Watch('onTabLoginRefresh') tabLoginRefresh: number = 0;
  // 宿主刷新请求（onPageShow / 切到本 Tab / profile 昵称校准完成时递增）：缓存优先重载三项统计
  @StorageLink('mineRefreshRequest') @Watch('onMineRefreshRequest') mineRefreshRequest: number = 0;
  @State isDark: boolean = isDarkMode();
  @StorageLink('fontScale') fontScale: number = 1.0;
  // 字号全局变更广播（2026-09-13）：@Watch 回写 fontScale 强制本页依赖刷新（离屏缓存不重绘兜底）
  @StorageLink('fontTick') @Watch('onFontTick') fontTick: number = 0;
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;

  aboutToAppear(): void {
    this.isDark = isDarkMode();
    // 顶部渐显带覆盖基准（平板收窄用）：取屏幕长边（竖屏视口高），窗口未 attach 时忽略
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      this.fadeCoverVp = Math.max(d.width, d.height) / d.densityPixels;
    } catch (e) {
      // 忽略：窗口未 attach，fadeCoverVp 保持 0 → topFadeStop() 回退手机比例
    }
    // 自含加载：挂载时 AuthManager 可能尚未 init 完（冷启动竞速），宿主 refreshLoginState
    // 完成后会立即递增 tabLoginRefresh，本页 @Watch 兜底再刷一次，保证竞速下数据不漏
    this.refreshAccountState();
    this.refreshMineStats();
  }

  /** 深色切换（来自本页或宿主）后重读全局状态 */
  onDarkTick(): void {
    this.isDark = isDarkMode();
  }

  /** fontTick 递增（字号设置写入 / 宿主返回广播）→ 显式回写 fontScale 强制本页字号依赖刷新 */
  onFontTick(): void {
    this.fontScale = AppStorage.get<number>('fontScale') ?? 1.0;
  }

  /** 登录/登出/换号广播（tabLoginRefresh 递增）：重读账号资料并重载三项统计 */
  onTabLoginRefresh(): void {
    this.refreshAccountState();
    this.refreshMineStats();
  }

  /** 宿主刷新请求（mineRefreshRequest 递增）：重读账号资料并缓存优先重载三项统计 */
  onMineRefreshRequest(): void {
    this.refreshAccountState();
    // 渲染时序规避（2026-11-10 真机实测）：切 Tab 时本 @Watch 与可见性翻转同帧触发，
    // 缓存读取耗时仅数毫秒、赋值可能赶在翻转帧渲染前被并帧处理。延迟到翻转帧之后
    // （组件已进入可见渲染态）再赋值，保证数值随切 Tab 动画即刻上屏。
    setTimeout(() => {
      this.refreshMineStats();
    }, 120);
  }

  /** 账号资料（本地读取，无网络）：登录态 + 昵称 + 头像；登出时统一清零统计显示 */
  private refreshAccountState(): void {
    this.loggedIn = AuthManager.getInstance().isLogin();
    const user: UserInfo | null = AuthManager.getInstance().getUser();
    this.userName = user?.name ?? '';
    this.userAvatar = user?.avatar ?? '';
    if (!this.loggedIn) {
      this.userStats = { postCount: -1, agreeCount: -1 };
      this.followUserCount = -1;
      this.statsLoading = false;
      this.statsError = false;
      this.followUserLoading = false;
      this.follows = [];
    }
  }

  /** 三项统计自含加载（缓存优先 SWR）：关注吧快照 / 用户统计 / 关注用户数 */
  private refreshMineStats(): void {
    if (!this.loggedIn) {
      return;
    }
    this.loadFollowsSnapshot();
    this.loadUserStats();
    this.loadFollowUserCount();
  }

  /** 关注吧快照：只读 FOLLOW_LIST 缓存（进吧页/关注操作维护完整快照），不发起网络；
   *  缓存未就绪时保持现值，进吧页落缓存后经刷新请求自动补齐 */
  private async loadFollowsSnapshot(): Promise<void> {
    try {
      const entry = await CacheManager.getInstance().getWithTtlAllowStale<FollowItem[]>(CACHE_KEY.FOLLOW_LIST);
      if (entry && entry.data.length > 0) {
        this.follows = entry.data;
        hilog.info(0x0000, 'MineStat', 'followSnapshot total=%{public}d expired=%{public}s',
          entry.data.length, `${entry.expired}`);
      } else {
        hilog.info(0x0000, 'MineStat', 'followSnapshot empty-or-miss');
      }
    } catch (e) {
      hilog.error(0x0000, 'MineStat', 'followSnapshot failed: %{public}s', `${(e as Error).message}`);
    }
  }

  private async loadUserStats(): Promise<void> {
    if (this.statsLoading || !this.loggedIn) {
      return;
    }
    const user = AuthManager.getInstance().getUser();
    const userId: string = user?.userId ?? '';
    if (userId.trim().length === 0) {
      this.userStats = { postCount: -1, agreeCount: -1 };
      this.statsError = true;
      return;
    }
    // 统计快照缓存直出（stale-while-revalidate）：每次刷新请求都会走到这里，
    // 有快照先秒开数字（新鲜则跳过网络），避免反复闪「…」加载态
    const statsCacheKey: string = `${CACHE_KEY.MINE_USER_STATS}_${userId}`;
    try {
      const entry = await CacheManager.getInstance().getWithTtlAllowStale<UserStats>(statsCacheKey);
      if (entry && entry.data.postCount >= 0) {
        this.userStats = entry.data;
        this.statsError = false;
        hilog.info(0x0000, 'MineStat', 'userStats cache postCount=%{public}d expired=%{public}s',
          entry.data.postCount, `${entry.expired}`);
        if (!entry.expired) {
          return;
        }
      } else {
        hilog.info(0x0000, 'MineStat', 'userStats cache miss');
      }
    } catch (e) {
      hilog.error(0x0000, 'MineStat', 'userStats cache read failed: %{public}s', `${(e as Error).message}`);
    }
    if (this.statsLoading) {
      return;
    }
    this.statsLoading = true;
    this.statsError = false;
    try {
      this.userStats = await TiebaService.getInstance().fetchUserStats(userId);
      hilog.info(0x0000, 'MineStat', 'userStats ok postCount=%{public}d agreeCount=%{public}d',
        this.userStats.postCount, this.userStats.agreeCount);
      await CacheManager.getInstance().putWithTtl(statsCacheKey, this.userStats, CACHE_TTL.MINE_USER_STATS);
    } catch (e) {
      hilog.error(0x0000, 'MineStat', 'userStats failed: %{public}s', `${(e as Error).message}`);
      // 已有缓存直出的数字时保留显示（不闪 '--'），否则降级 '--'
      if (this.userStats.postCount < 0) {
        this.statsError = true;
      }
    } finally {
      this.statsLoading = false;
    }
  }

  /** 加载当前登录用户的关注用户总数（follow_list 接口 total 字段；快照缓存直出 + 失败保留已显数字） */
  private async loadFollowUserCount(): Promise<void> {
    if (this.followUserLoading || !this.loggedIn) {
      return;
    }
    const userId: string = AuthManager.getInstance().getUser()?.userId ?? '';
    // 关注用户总数快照缓存直出（stale-while-revalidate）：同 loadUserStats
    const countCacheKey: string = `${CACHE_KEY.MINE_FOLLOW_USER_COUNT}_${userId}`;
    try {
      const entry = await CacheManager.getInstance().getWithTtlAllowStale<number>(countCacheKey);
      if (entry && entry.data >= 0) {
        this.followUserCount = entry.data;
        hilog.info(0x0000, 'MineStat', 'followUserCount cache total=%{public}d expired=%{public}s',
          entry.data, `${entry.expired}`);
        if (!entry.expired) {
          return;
        }
      } else {
        hilog.info(0x0000, 'MineStat', 'followUserCount cache miss');
      }
    } catch (e) {
      hilog.error(0x0000, 'MineStat', 'followUserCount cache read failed: %{public}s', `${(e as Error).message}`);
    }
    if (this.followUserLoading) {
      return;
    }
    this.followUserLoading = true;
    try {
      const result = await TiebaService.getInstance().fetchFollowUserList(0, 1);
      hilog.info(0x0000, 'MineStat', 'followUserCount ok total=%{public}d list=%{public}d',
        result.total, result.list.length);
      this.followUserCount = result.total > 0 ? result.total : result.list.length;
      if (userId.trim().length > 0) {
        await CacheManager.getInstance().putWithTtl(countCacheKey, this.followUserCount,
          CACHE_TTL.MINE_FOLLOW_USER_COUNT);
      }
    } catch (e) {
      hilog.error(0x0000, 'MineStat', 'followUserCount failed: %{public}s', `${(e as Error).message}`);
      // 已有缓存直出的数字时保留显示，否则维持 '-1' 降级 '--'
    } finally {
      this.followUserLoading = false;
    }
  }

  private statText(value: number): string {
    if (this.statsLoading) {
      return '…';
    }
    if (value < 0 || this.statsError) {
      return '--';
    }
    return `${value}`;
  }

  private followUserCountText(): string {
    if (this.followUserLoading) {
      return '…';
    }
    if (this.followUserCount < 0) {
      return '--';
    }
    return `${this.followUserCount}`;
  }

  private openLogin(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/Login' });
  }

  /** 头像点击：跳转本人用户主页（本人主页隐藏关注/拉黑按钮） */
  private openMyProfile(): void {
    if (!AuthManager.getInstance().isLogin()) {
      this.openLogin();
      return;
    }
    const id: string = `${AuthManager.getInstance().getUser()?.userId ?? ''}`.trim();
    if (id.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '用户信息暂不可用' });
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UserProfile',
      params: { userId: id, userName: this.userName }
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '用户主页打开失败，请稍后重试' });
    });
  }

  private openPersonalContent(mode: string): void {
    if (!this.loggedIn && mode !== 'history') {
      this.openLogin();
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/PersonalContent',
      params: { mode }
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '页面打开失败，请稍后重试' });
    });
  }

  /** 一键签到入口（由进吧页顶栏迁移至此）：登录校验后自增 signAllRequest，
   *  由常驻的 ForumsTab 监听触发既有签到全流程（进度弹窗 / 后台签到 / 结果通知）。 */
  private requestSignAll(): void {
    if (!this.loggedIn) {
      this.openLogin();
      return;
    }
    AppStorage.setOrCreate<number>('signAllRequest', (AppStorage.get<number>('signAllRequest') ?? 0) + 1);
    this.getUIContext().getPromptAction().showToast({ message: '开始一键签到…' });
  }

  private openFollowList(): void {
    if (!this.loggedIn) {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录后查看关注列表' });
      return;
    }
    this.getUIContext().getRouter().pushUrl({ url: 'pages/FollowList' }).catch(() => {
    });
  }

  /** 兜底路径专用（MINE_OFFICIAL_TITLE_BAR = false 时才挂载）：页面主体悬浮自绘玻璃 TopBar */
  @Builder
  TopBar() {
    Row() {
      Column({ space: 3 }) {
        Text('我的')
          .fontSize(fs(22, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.isDark))
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      Button() {
        SymbolGlyph(this.isDark
          ? $r('sys.symbol.sun_max_fill')
          : $r('sys.symbol.moon_fill'))
          .fontColor([Theme.iconPrimary(this.isDark)])
          .fontSize(fs(20, this.fontScale))
      }
      .width(44)
      .height(44)
      .backgroundColor(Theme.segGlass(this.isDark, false))
      .border({ width: 0.5, color: Theme.manualGlassBorder() })
      .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
      .shadow(Theme.segGlassShadow(this.isDark, false))
      .borderRadius(Radius.full)
      .margin({ left: 12 })
      .accessibilityText('切换深色模式')
      .onClick(() => {
        this.isDark = !this.isDark;
        // 用户主动切换：写 manual + 关跟随系统（避免 onConfigurationUpdate 在 setColorMode 异步窗口内
        // 拿到旧 Configuration 反向拉回档位）。与 PersonalizedPage 「深色模式」开关完全等价。
        UsageHabitsManager.getInstance().setFollowSystemDark(false);
        UsageHabitsManager.getInstance().setDarkModeManual(this.isDark);
        setDarkMode(this.isDark);
        AppStorage.setOrCreate<number>('darkTick', (AppStorage.get<number>('darkTick') ?? 0) + 1);
      })
    }
    .width('100%')
    .padding({ left: this.pageMargin, right: this.pageMargin, top: 44, bottom: 10 })
    .backgroundColor(Color.Transparent)
    .zIndex(14)
  }

  /**
   * 官方槽位标题栏（§6.10 同机制，与进吧 ForumsTitleBar 同构）：「我的」标题 + 右上角深色切换 44 圆钮。
   * 圆钮玻璃换成 `ImmMaterial.seg(false)`（THIN 中性档），四项自绘玻璃（segGlass / border /
   * backgroundBlurStyle / segGlassShadow）按坑 24 全删；`Button` 显式 backgroundColor(Color.Transparent)
   * 清默认品牌蓝填充。几何（top 44 / bottom 10 / 左右 Spacing.lg / 圆钮 44 / margin left 12）逐项一致；
   * zIndex(14) 槽内无叠层序需求，去掉。
   */
  @Builder
  MineTitleBar() {
    Row() {
      Column({ space: 3 }) {
        Text('我的')
          .fontSize(fs(22, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.isDark))
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      Button() {
        SymbolGlyph(this.isDark
          ? $r('sys.symbol.sun_max_fill')
          : $r('sys.symbol.moon_fill'))
          .fontColor([Theme.iconPrimary(this.isDark)])
          .fontSize(fs(20, this.fontScale))
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .systemMaterial(ImmMaterial.seg(false))
      .borderRadius(Radius.full)
      .margin({ left: 12 })
      .accessibilityText('切换深色模式')
      .onClick(() => {
        this.isDark = !this.isDark;
        // 用户主动切换：写 manual + 关跟随系统（避免 onConfigurationUpdate 在 setColorMode 异步窗口内
        // 拿到旧 Configuration 反向拉回档位）。与 PersonalizedPage 「深色模式」开关完全等价。
        UsageHabitsManager.getInstance().setFollowSystemDark(false);
        UsageHabitsManager.getInstance().setDarkModeManual(this.isDark);
        setDarkMode(this.isDark);
        AppStorage.setOrCreate<number>('darkTick', (AppStorage.get<number>('darkTick') ?? 0) + 1);
      })
    }
    .width('100%')
    .padding({ left: this.pageMargin, right: this.pageMargin, top: 44, bottom: 10 })
  }

  @Builder
  UserAvatar(size: number) {
    Stack() {
      Text(this.userName.length > 0 ? this.userName.charAt(0).toUpperCase() : '我')
        .fontSize(Math.max(16, Math.floor(size * 0.38)))
        .fontColor(Color.White)
        .width(size)
        .height(size)
        .textAlign(TextAlign.Center)
        .borderRadius(size / 2)
        .backgroundColor(Theme.brand())
      if (this.userAvatar.trim().length > 0) {
        Image(this.userAvatar.trim())
          .width(size)
          .height(size)
          .borderRadius(size / 2)
          .objectFit(ImageFit.Cover)
      }
    }
    .width(size)
    .height(size)
    .onClick(() => {
      this.openMyProfile();
    })
  }

  @Builder
  MineEntry(icon: Resource, title: string, subtitle: string, onTap: () => void) {
    Row({ space: Spacing.md }) {
      SymbolGlyph(icon)
        .fontSize(fs(20, this.fontScale))
        .fontColor([Theme.iconPrimary(this.isDark)])
        .width(28)
      Column({ space: 4 }) {
        Text(title)
          .fontSize(fs(15, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
        Text(subtitle)
          .fontSize(fs(11, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(fs(18, this.fontScale))
        .fontColor([Theme.textTertiary(this.isDark)])
    }
    .width('100%')
    .padding({ left: this.pageMargin, right: this.pageMargin, top: 13, bottom: 13 })
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.lg * this.cardRadiusScale)
    .onClick(() => onTap())
  }

  /** 页面内容层（原 build() 根 Stack 的 List，槽位 / 兜底两条路径共用） */
  @Builder
  MineContent() {
    List() {
        // 预留TopBar高度作为初始间距
        ListItem() {
          Column()
            .width('100%')
            .height(90)
        }
        .backgroundColor(Color.Transparent)

        ListItem() {
        Column({ space: Spacing.md }) {
          if (this.loggedIn) {
            Row({ space: Spacing.md }) {
              this.UserAvatar(62)
              Column({ space: 5 }) {
                Text(this.userName || '贴吧用户')
                  .fontSize(fs(19, this.fontScale))
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.textPrimary(this.isDark))
                Text('已登录 · 个人主页')
                  .fontSize(fs(12, this.fontScale))
                  .fontColor(Theme.textSecondary(this.isDark))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('›')
                .fontSize(fs(24, this.fontScale))
                .fontColor(Theme.textTertiary(this.isDark))
            }
            .width('100%')
            .onClick(() => { this.openMyProfile(); })
            .padding(Spacing.lg)
            .backgroundColor(Theme.bgCard(this.isDark))
            .borderRadius(Radius.lg * this.cardRadiusScale)
          } else {
            Row() {
              Column({ space: 5 }) {
                Text('登录贴吧')
                  .fontSize(fs(18, this.fontScale))
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.textPrimary(this.isDark))
                Text('登录后同步你的关注、收藏与历史')
                  .fontSize(fs(12, this.fontScale))
                  .fontColor(Theme.textSecondary(this.isDark))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Button('登录')
                .fontSize(fs(13, this.fontScale))
                .fontColor($r('sys.color.font_on_primary'))
                .backgroundColor(Theme.manualGlass(this.isDark, true))
                .border({ width: 0.5, color: Theme.manualGlassBorder() })
                .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.accent())
                .systemMaterial(ImmMaterial.accent(this.isDark))
                .borderRadius(Radius.full)
                .onClick(() => this.openLogin())
            }
            .width('100%')
            .padding(Spacing.lg)
            .backgroundColor(Theme.bgCard(this.isDark))
            .borderRadius(Radius.lg * this.cardRadiusScale)
            .onClick(() => this.openLogin())
          }

          Row() {
            // 统计数值直绑内联（2026-11-10 0/--/-- 根因修复）：@Builder 按值传参（字符串参数）
            // 不随状态变量刷新（ArkUI 文档规则，官方反例即 `${this.label}` 传参），原 this.StatItem(...)
            // 三参在首次求值后被永久冻结。改为在此处（组件渲染作用域内）直接求值绑定，
            // follows/userStats/followUserCount 变化即触发本行局部重渲染。
            Column({ space: 4 }) {
              Text(`${this.follows.length}`)
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary(this.isDark))
              Text('关注的吧')
                .fontSize(fs(11, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .layoutWeight(1)
            Divider().vertical(true).height(28).color(Theme.divider(this.isDark))
            Column({ space: 4 }) {
              Text(this.followUserCountText())
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary(this.isDark))
              Text('关注用户')
                .fontSize(fs(11, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .layoutWeight(1)
            .onClick(() => { this.openFollowList(); })
            Divider().vertical(true).height(28).color(Theme.divider(this.isDark))
            Column({ space: 4 }) {
              Text(this.statText(this.userStats.postCount))
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary(this.isDark))
              Text('我的贴子')
                .fontSize(fs(11, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: Spacing.lg, bottom: Spacing.lg })
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg * this.cardRadiusScale)

          this.MineEntry($r('sys.symbol.doc'), '我的帖子', '查看发布过的主题', () => this.openPersonalContent('posts'))
          this.MineEntry($r('sys.symbol.star'), '我的收藏', '收藏的帖子与内容', () => {
            if (!this.loggedIn) {
              this.openLogin();
              return;
            }
            this.openFavorite();
          })
          this.MineEntry($r('sys.symbol.heart'), '我的点赞', '点赞过的内容', () => this.openPersonalContent('likes'))
          this.MineEntry($r('sys.symbol.clock'), '浏览历史', '最近看过的帖子和吧', () => this.openPersonalContent('history'))
          this.MineEntry($r('sys.symbol.checkmark_circle'), '一键签到', '为全部关注的吧一键签到', () => this.requestSignAll())
          this.MineEntry($r('sys.symbol.plus'), '创建吧', '创建并管理贴吧', () => this.getUIContext().getPromptAction().showToast({ message: '创建吧需要贴吧官方接口支持' }))
          this.MineEntry($r('sys.symbol.gearshape'), '软件设置', '通知、缓存、隐私与关于', () => {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/Settings' }).catch(() => {
            this.getUIContext().getPromptAction().showToast({ message: '页面打开失败，请稍后重试' });
          });
        })

          if (this.loggedIn) {
            Button('退出登录')
              .width('100%')
              .height(44)
              .fontSize(fs(14, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.danger())
              .backgroundColor(Theme.segGlass(this.isDark, false))
              .border({ width: 0.5, color: Theme.manualGlassBorder() })
              .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
              .shadow(Theme.segGlassShadow(this.isDark, false))
              .borderRadius(Radius.lg * this.cardRadiusScale)
              .onClick(() => {
                this.onLogout();
              })
          }
        }
        .width('100%')
        .padding({ left: this.pageMargin, right: this.pageMargin, top: Spacing.md, bottom: 150 })
      }
      }
    .width('100%')
    .layoutWeight(1)
    .padding({ bottom: 150 })
    .scrollBar(BarState.Off)
    .clip(false)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .linearGradientBlur(TopBarFx.blur(this.tbxTick), { fractionStops: [[1.0, 0.0], [1.0, TopBarFx.solid(this.tbxTick)], [0.0, TopBarFx.fade(this.tbxTick)], [0.0, 1.0]], direction: GradientDirection.Bottom })
    .overlay(() => { TopGlassVeil() })
  }

  build() {
    if (MINE_OFFICIAL_TITLE_BAR) {
      // 官方槽位路径（§6.10）：标题行整行搬进 Navigation title 槽位吃真材质
      Navigation() {
        this.MineContent()
      }
      .title({ builder: this.MineTitleBar(), height: MINE_TITLE_BAR_HEIGHT },
        { barStyle: BarStyle.STACK, backgroundColor: Color.Transparent })
      .mode(NavigationMode.Stack)
      .hideTitleBar(false)
      .hideBackButton(true)
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .clip(false)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    } else {
      // 兜底路径：页面主体悬浮自绘玻璃（改造前原样）
      Stack({ alignContent: Alignment.TopStart }) {
        this.MineContent()

        // 悬浮TopBar层（内容可穿过TopBar区域）
        this.TopBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
    }
  }
}
