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

import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CacheManager } from '../cache/CacheManager';
import { TopBarFx } from '../components/TopBarFx';
import { CACHE_KEY } from '../common/Constants';
import { DEFAULT_PAGE_MARGIN, DEFAULT_CARD_RADIUS_SCALE, DEFAULT_RECENT_AVATAR_SIZE, isWideBarFlatDevice } from '../common/Theme';

const TAG: string = 'UsageHabitsManager';

/**
 * 全局使用习惯开关管理器（单例）。
 * - 管理「首页推荐仅显示关注吧的帖子」开关
 * - 持久化到本地缓存
 * - 通过 AppStorage 通知所有页面刷新（键：homeOnlyFollow）
 */
export class UsageHabitsManager {
  private static instance: UsageHabitsManager | null = null;
  // 并发防重（2026-11-10 修复「首页隐藏时冷启动闪现首页再切走」）：缓存进行中/已完成的初始化 Promise。
  // 旧实现 inited 布尔在恢复完成前就置位，后到的并发调用方（Index.aboutToAppear 与 EntryAbility
  // loadContent 回调冷启动竞态）立即返回，读到尚未恢复的 AppStorage（defaultTab/dockHidden 回退
  // 初值 → 启动落点算成首页）。改为共享同一个 Promise：所有调用方等待同一次恢复完成，与调用先后无关。
  private initPromise: Promise<void> | null = null;
  private context: common.UIAbilityContext | null = null;

  static getInstance(): UsageHabitsManager {
    if (UsageHabitsManager.instance === null) {
      UsageHabitsManager.instance = new UsageHabitsManager();
    }
    return UsageHabitsManager.instance;
  }

  /**
   * 初始化：从缓存恢复开关状态（并发安全：所有调用方共享同一次恢复）
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initPromise !== null) {
      return this.initPromise;
    }
    this.context = context;
    const task: Promise<void> = this.doInit(context);
    this.initPromise = task;
    task.catch(() => {
    });
    return task;
  }

  private async doInit(context: common.UIAbilityContext): Promise<void> {
    try {
      const cache = CacheManager.getInstance();
      await cache.init(context);
      const saved = await cache.get(CACHE_KEY.HOME_ONLY_FOLLOW);
      AppStorage.setOrCreate('homeOnlyFollow', saved === '1');
      // 深色模式设置：跟随系统（默认 true）与手动深色（默认 false）一并恢复；
      // 旧版本未写过这两个 key 时，cache.get 返回 null，按默认值落地、保持原「跟随系统」行为。
      const savedFollowSys = await cache.get(CACHE_KEY.FOLLOW_SYSTEM_DARK);
      AppStorage.setOrCreate('appFollowSystemDark', savedFollowSys !== '0');
      const savedDark = await cache.get(CACHE_KEY.DARK_MODE);
      AppStorage.setOrCreate('appDarkMode', savedDark === '1');
      // 「关闭自动旋转」（仅阔直屏直板显示/生效）：缺省 null → 不关（允许旋转），老用户升级零回归
      const savedAutoRotate = await cache.get(CACHE_KEY.AUTO_ROTATE);
      AppStorage.setOrCreate('autoRotateOff', savedAutoRotate === '1');
      // 页面边距范围为 0~24 vp。
      const savedPageMargin = await cache.get(CACHE_KEY.PAGE_MARGIN);
      const pmRaw: number = Number.parseInt(savedPageMargin ?? '', 10);
      const pmVal: number = Number.isNaN(pmRaw) ? DEFAULT_PAGE_MARGIN : Math.max(0, Math.min(24, pmRaw));
      AppStorage.setOrCreate('pageMargin', pmVal);
      const savedFloatingPageBars = await cache.get(CACHE_KEY.FLOATING_PAGE_BARS);
      AppStorage.setOrCreate('floatingPageBars', savedFloatingPageBars !== '0');
      AppStorage.setOrCreate('bottomBarBackdrop', await cache.get(CACHE_KEY.BOTTOM_BAR_BACKDROP) === '1');
      // Dock 栏顺序：缺省 null → 默认 0,1,2,3,4
      const savedDockOrder = await cache.get(CACHE_KEY.DOCK_ORDER);
      AppStorage.setOrCreate('dockOrder', UsageHabitsManager.normalizeDockOrder(savedDockOrder));
      // Dock 隐藏项：缺省 null → 无隐藏（全部展示）
      const savedDockHidden = await cache.get(CACHE_KEY.DOCK_HIDDEN);
      AppStorage.setOrCreate('dockHidden', UsageHabitsManager.normalizeDockHidden(savedDockHidden));
      // 启动默认显示界面：缺省 null → 0（首页）；范围 0~4
      const savedDefaultTab = await cache.get(CACHE_KEY.DEFAULT_TAB);
      const dtRaw: number = Number.parseInt(savedDefaultTab ?? '0', 10);
      AppStorage.setOrCreate('defaultTab', (dtRaw >= 0 && dtRaw <= 4) ? dtRaw : 0);
      // 切页平移动画开关：缺省 null → 开（保持原有动效）
      const savedTabAnim = await cache.get(CACHE_KEY.TAB_ANIMATION);
      AppStorage.setOrCreate('tabAnimEnabled', savedTabAnim !== '0');
      // 「列数调整」档位：缺省 null → 0（默认自动适配），老用户升级逐像素零回归
      const savedColumnMode = await cache.get(CACHE_KEY.COLUMN_MODE);
      const cm: number = Number.parseInt(savedColumnMode ?? '0', 10);
      AppStorage.setOrCreate('columnMode', (cm === 1 || cm === 2) ? cm : 0);
      // 「帖子沉浸式阅读」：缺省 null → 关闭，老用户升级零行为变化
      const savedImmersiveRead = await cache.get(CACHE_KEY.IMMERSIVE_READ);
      AppStorage.setOrCreate('immersiveReading', savedImmersiveRead === '1');
      // 「沉浸式阅读补全」（独立开关项，不与主开关联挂）：缺省 null → 关闭，老用户升级零行为变化
      const savedImmersiveExtra = await cache.get(CACHE_KEY.IMMERSIVE_READ_EXTRA);
      AppStorage.setOrCreate('immersiveReadExtra', savedImmersiveExtra === '1');
      // 「帖子极速开启」：缺省 null → 关闭（用户拍板默认关闭），仅显式开启过的用户保持开
      const savedFastOpen = await cache.get(CACHE_KEY.THREAD_FEED_PREFETCH);
      AppStorage.setOrCreate('threadFastOpen', savedFastOpen === '1');
      // 「仅 WiFi 启用」：缺省 null → 开启（用户拍板默认开启），主开关开启时生效
      const savedFastWifi = await cache.get(CACHE_KEY.THREAD_FAST_WIFI);
      AppStorage.setOrCreate('threadFastWifi', savedFastWifi !== '0');
      // 「吧主页默认进入界面」：缺省 null → 0（热门，用户拍板默认档），老用户升级零回归
      const savedForumSort = await cache.get(CACHE_KEY.FORUM_DEFAULT_SORT);
      AppStorage.setOrCreate('forumDefaultSort', UsageHabitsManager.normalizeForumSort(savedForumSort));
      // 「楼中楼回复字号」整体缩放：缺省 0.9（比楼层正文略小），范围 0.7~1.2
      const savedSubReplyScale = await cache.get(CACHE_KEY.SUB_REPLY_SCALE);
      const srRaw: number = Number.parseFloat(savedSubReplyScale ?? '0.9');
      AppStorage.setOrCreate('subReplyScale', (isNaN(srRaw) || srRaw < 0.7 || srRaw > 1.2) ? 0.9 : srRaw);
      const savedTopBlur = await cache.get(CACHE_KEY.TOP_BAR_BLUR);
      const savedTopSolid = await cache.get(CACHE_KEY.TOP_BAR_SOLID);
      const savedTopFade = await cache.get(CACHE_KEY.TOP_BAR_FADE);
      const topFade: number = UsageHabitsManager.normalizeTopFade(savedTopFade);
      const topSolid: number = topFade === 0 ? 0 : UsageHabitsManager.normalizeTopSolid(savedTopSolid);
      AppStorage.setOrCreate('tbx_blur', UsageHabitsManager.normalizeTopBlur(savedTopBlur));
      AppStorage.setOrCreate('tbx_solid', topSolid);
      AppStorage.setOrCreate('tbx_fade', topFade > 0 && topFade <= topSolid ? topSolid + 0.02 : topFade);
      const savedCardRadiusScale = await cache.get(CACHE_KEY.CARD_RADIUS_SCALE);
      AppStorage.setOrCreate('cardRadiusScale', UsageHabitsManager.normalizeCardRadiusScale(savedCardRadiusScale));
      const savedRecentAvatarSize = await cache.get(CACHE_KEY.RECENT_AVATAR_SIZE);
      AppStorage.setOrCreate('recentAvatarSize', UsageHabitsManager.normalizeRecentAvatarSize(savedRecentAvatarSize));
      // 冷启动可能早于各列表页构造：bump 一次 tick，让已构造的页面重读档位（未构造页 aboutToAppear 自会读）
      AppStorage.setOrCreate('columnModeTick', (AppStorage.get<number>('columnModeTick') ?? 0) + 1);
    } catch (e) {
      // 忽略缓存错误，使用默认值（关闭 / 跟随系统 / 允许旋转 / 列数默认档 / 沉浸阅读关）
      AppStorage.setOrCreate('homeOnlyFollow', false);
      AppStorage.setOrCreate('appFollowSystemDark', true);
      AppStorage.setOrCreate('appDarkMode', false);
      AppStorage.setOrCreate('autoRotateOff', false);
      AppStorage.setOrCreate('columnMode', 0);
      AppStorage.setOrCreate('immersiveReading', false);
      AppStorage.setOrCreate('immersiveReadExtra', false);
      AppStorage.setOrCreate('pageMargin', DEFAULT_PAGE_MARGIN);
      AppStorage.setOrCreate('floatingPageBars', true);
      AppStorage.setOrCreate('bottomBarBackdrop', false);
      AppStorage.setOrCreate('dockOrder', '0,1,2,3,4');
      AppStorage.setOrCreate('dockHidden', '');
      AppStorage.setOrCreate('defaultTab', 0);
      AppStorage.setOrCreate('tabAnimEnabled', true);
      AppStorage.setOrCreate('threadFastOpen', false);
      AppStorage.setOrCreate('threadFastWifi', true);
      AppStorage.setOrCreate('forumDefaultSort', 0);
      AppStorage.setOrCreate('subReplyScale', 0.9);
      AppStorage.setOrCreate('tbx_blur', TopBarFx.DEFAULT_BLUR);
      AppStorage.setOrCreate('tbx_solid', TopBarFx.DEFAULT_SOLID);
      AppStorage.setOrCreate('tbx_fade', TopBarFx.DEFAULT_FADE);
      AppStorage.setOrCreate('cardRadiusScale', DEFAULT_CARD_RADIUS_SCALE);
      AppStorage.setOrCreate('recentAvatarSize', DEFAULT_RECENT_AVATAR_SIZE);
    }
  }

  /**
   * 当前是否开启「仅推荐关注的吧」
   */
  isOnlyFollow(): boolean {
    return AppStorage.get<boolean>('homeOnlyFollow') ?? false;
  }

  /**
   * 设置开关状态：立即更新 AppStorage，持久化到本地，
   * 并清除首页推荐缓存，避免下次读到旧的未过滤内容。
   */
  async setOnlyFollow(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('homeOnlyFollow', enabled);
    try {
      if (this.context) {
        const cache = CacheManager.getInstance();
        await cache.init(this.context);
        await cache.put(CACHE_KEY.HOME_ONLY_FOLLOW, enabled ? '1' : '0');
        // 开关状态变化后旧缓存（可能未过滤/已过滤）不再可信，直接清除
        await cache.delete(CACHE_KEY.THREAD_LIST);
      }
    } catch (e) {
      // 忽略持久化错误
    }
  }

  /**
   * 当前手动深色模式设置（仅当 followSystemDark=false 时生效）。
   * 默认 false：旧版本用户未设置时，按 v1.x 「浅色」语义落地。
   */
  isDarkModeManual(): boolean {
    return AppStorage.get<boolean>('appDarkMode') ?? false;
  }

  /**
   * 设置手动深色模式：立即更新 AppStorage 并落盘。
   * 注意：本方法只改持久化值，**不**触发 Configuration 重切；UI 需自行调 Theme.setDarkMode 让系统档位与状态栏跟随。
   */
  async setDarkModeManual(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('appDarkMode', enabled);
    this.persistDarkMode(enabled).catch(() => {
    });
  }

  /**
   * 当前是否「跟随系统深色模式」。默认 true，保持 v1.x 「跟随系统」行为。
   */
  isFollowSystemDark(): boolean {
    return AppStorage.get<boolean>('appFollowSystemDark') ?? true;
  }

  /**
   * 设置「跟随系统深色模式」开关。开启时只翻档位，调用方需另行调 Theme.setDarkMode 把当前系统态应用一遍；
   * 关闭时只翻档位不切色，调用方需自行决定「以手动深色重新应用一遍」。
   */
  async setFollowSystemDark(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('appFollowSystemDark', enabled);
    this.persistFollowSystemDark(enabled).catch(() => {
    });
  }

  /**
   * 「列数调整」当前档位：0 = 默认（按机型自动适配横竖屏）/ 1 = 竖二横三 / 2 = 竖三横四。
   * 仅在大屏形态生效（判定见 Theme.isLargeScreenForm），手机档 / 窄窗一律不覆盖。
   */
  getColumnMode(): number {
    const v: number = AppStorage.get<number>('columnMode') ?? 0;
    return (v === 1 || v === 2) ? v : 0;
  }

  /**
   * 设置「列数调整」档位：写 AppStorage 并落盘，同时递增 columnModeTick 广播。
   * 各列表页以 @StorageLink('columnModeTick') @Watch 回写本地档位 → 重算分桶 + 强制回到列表顶部
   * （离屏缓存页 @StorageLink 同步不重绘，tick + 本地 @State 是工程既有兜底范式，同 fontTick）。
   */
  async setColumnMode(mode: number): Promise<void> {
    const v: number = (mode === 1 || mode === 2) ? mode : 0;
    AppStorage.setOrCreate('columnMode', v);
    AppStorage.setOrCreate('columnModeTick', (AppStorage.get<number>('columnModeTick') ?? 0) + 1);
    this.persistColumnMode(v).catch(() => {
    });
  }

  private async persistColumnMode(mode: number): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.COLUMN_MODE, `${mode}`);
    } catch (e) {
      // 忽略持久化错误
    }
  }

  /** Dock 顺序规范化：仅接受 0~4 的五个互异 TabIndex，缺失自动补齐、非法回退默认 */
  private static normalizeDockOrder(raw: string | null | undefined): string {
    const parts: string[] = (raw ?? '').split(',');
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
    return out.join(',');
  }

  /** 页面左右留白（vp，0~24） */
  getPageMargin(): number {
    return AppStorage.get<number>('pageMargin') ?? DEFAULT_PAGE_MARGIN;
  }

  async setPageMargin(margin: number): Promise<void> {
    const v: number = Math.max(0, Math.min(24, Math.round(margin)));
    AppStorage.setOrCreate('pageMargin', v);
    this.persistString(CACHE_KEY.PAGE_MARGIN, `${v}`).catch(() => {
    });
  }

  /** Dock 栏顺序（TabIndex 逗号串） */
  getDockOrderValue(): string {
    return AppStorage.get<string>('dockOrder') ?? '0,1,2,3,4';
  }

  async setDockOrder(order: string): Promise<void> {
    const normalized: string = UsageHabitsManager.normalizeDockOrder(order);
    AppStorage.setOrCreate('dockOrder', normalized);
    this.persistString(CACHE_KEY.DOCK_ORDER, normalized).catch(() => {
    });
  }

  /** Dock 隐藏项规范化：仅接受 0~4 的互异 TabIndex；若全部隐藏则至少放出一个 */
  private static normalizeDockHidden(raw: string | null | undefined): string {
    const out: number[] = UsageHabitsManager.parseIndexList(raw ?? '');
    if (out.length >= 5) {
      out.length = 4;
    }
    return out.join(',');
  }

  /** 解析逗号分隔的 TabIndex 列表（去重、过滤非法值） */
  private static parseIndexList(raw: string): number[] {
    const parts: string[] = (raw ?? '').split(',');
    const out: number[] = [];
    for (let i = 0; i < parts.length; i++) {
      const n: number = Number.parseInt(parts[i].trim(), 10);
      if (!Number.isNaN(n) && n >= 0 && n <= 4 && out.indexOf(n) < 0) {
        out.push(n);
      }
    }
    return out;
  }

  /** Dock 隐藏项（TabIndex 逗号串） */
  getDockHiddenValue(): string {
    return AppStorage.get<string>('dockHidden') ?? '';
  }

  getDockHiddenArr(): number[] {
    return UsageHabitsManager.parseIndexList(this.getDockHiddenValue());
  }

  isTabHidden(index: number): boolean {
    return this.getDockHiddenArr().indexOf(index) >= 0;
  }

  /** 首个可见 Tab（启动/隐藏当前页时回退用），保证返回合法 0~4 */
  getFirstVisibleTab(): number {
    const order: number[] = UsageHabitsManager.parseIndexList(AppStorage.get<string>('dockOrder') ?? '0,1,2,3,4');
    const hidden: number[] = this.getDockHiddenArr();
    for (let i = 0; i < order.length; i++) {
      if (hidden.indexOf(order[i]) < 0) {
        return order[i];
      }
    }
    return 0;
  }

  async setDockHidden(hidden: string): Promise<void> {
    const normalized: string = UsageHabitsManager.normalizeDockHidden(hidden);
    AppStorage.setOrCreate('dockHidden', normalized);
    this.persistString(CACHE_KEY.DOCK_HIDDEN, normalized).catch(() => {
    });
  }

  /** 启动默认显示界面（TabIndex 0~4） */
  getDefaultTab(): number {
    const v: number = AppStorage.get<number>('defaultTab') ?? 0;
    return (v >= 0 && v <= 4) ? v : 0;
  }

  async setDefaultTab(tab: number): Promise<void> {
    const v: number = (tab >= 0 && tab <= 4) ? tab : 0;
    AppStorage.setOrCreate('defaultTab', v);
    this.persistString(CACHE_KEY.DEFAULT_TAB, `${v}`).catch(() => {
    });
  }

  /** 切页平移动画开关（true=播放；false=瞬时切换） */
  isTabAnimationEnabled(): boolean {
    return AppStorage.get<boolean>('tabAnimEnabled') ?? true;
  }

  async setTabAnimationEnabled(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('tabAnimEnabled', enabled);
    this.persistString(CACHE_KEY.TAB_ANIMATION, enabled ? '1' : '0').catch(() => {
    });
  }

  private async persistString(key: string, value: string): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(key, value);
    } catch (e) {
      // 忽略持久化错误
    }
  }

  async setFloatingPageBars(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('floatingPageBars', enabled);
    await this.persistString(CACHE_KEY.FLOATING_PAGE_BARS, enabled ? '1' : '0');
  }

  async setBottomBarBackdrop(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('bottomBarBackdrop', enabled);
    await this.persistString(CACHE_KEY.BOTTOM_BAR_BACKDROP, enabled ? '1' : '0');
  }

  /**
   * 当前是否开启「帖子沉浸式阅读」（详情页向下滑动自动收起顶栏与底栏）。默认 false，保持既有行为。
   * 真源为 AppStorage（详情页 / 楼中楼页用 @StorageLink 直接同步），manager 只负责冷启动恢复与落盘。
   */
  isImmersiveReading(): boolean {
    return AppStorage.get<boolean>('immersiveReading') ?? false;
  }

  /**
   * 设置「帖子沉浸式阅读」：立即更新 AppStorage 并落盘。
   * 注意：页面内「已藏起」是页面局部 @State（绝不写 AppStorage，否则切页 / 换帖会残留隐藏态）；
   * 详情页以 @Watch 监听本值，关闭开关时立即把顶栏与底栏恢复显示。
   */
  async setImmersiveReading(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('immersiveReading', enabled);
    this.persistImmersiveRead(enabled).catch(() => {
    });
  }

  /**
   * 当前是否开启「沉浸式阅读补全」（独立开关项，不与主开关联挂）：开启后首页 / 收藏页 /
   * 收藏夹二级页 / 吧主页向下滑动自动收起顶栏与底栏。默认 false，保持既有行为。
   * 真源为 AppStorage（各页用 @StorageLink 直接同步），manager 只负责冷启动恢复与落盘。
   */
  isImmersiveReadExtra(): boolean {
    return AppStorage.get<boolean>('immersiveReadExtra') ?? false;
  }

  /** 设置「沉浸式阅读补全」：立即更新 AppStorage 并落盘（页面局部隐藏态纪律与主开关相同）。 */
  async setImmersiveReadExtra(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('immersiveReadExtra', enabled);
    this.persistImmersiveReadExtra(enabled).catch(() => {
    });
  }

  /**
   * 当前是否开启「帖子极速开启」（feed 首屏前 3 卡详情+图片预取）。默认 false（关闭），用户拍板。
   * 真源为 AppStorage（服务层预取入口直接读），manager 只负责冷启动恢复与落盘。
   */
  isThreadFastOpen(): boolean {
    return AppStorage.get<boolean>('threadFastOpen') ?? false;
  }

  /** 设置「帖子极速开启」：立即更新 AppStorage 并落盘。 */
  async setThreadFastOpen(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('threadFastOpen', enabled);
    this.persistThreadFastOpen(enabled).catch(() => {
    });
  }

  private async persistThreadFastOpen(enabled: boolean): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.THREAD_FEED_PREFETCH, enabled ? '1' : '0');
    } catch (e) {
      // 忽略持久化错误
    }
  }

  /** 当前是否「仅 WiFi 启用」极速预取。默认 true（开启）。 */
  isThreadFastWifi(): boolean {
    return AppStorage.get<boolean>('threadFastWifi') ?? true;
  }

  /** 设置「仅 WiFi 启用」：立即更新 AppStorage 并落盘。 */
  async setThreadFastWifi(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('threadFastWifi', enabled);
    this.persistThreadFastWifi(enabled).catch(() => {
    });
  }

  private async persistThreadFastWifi(enabled: boolean): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.THREAD_FAST_WIFI, enabled ? '1' : '0');
    } catch (e) {
      // 忽略持久化错误
    }
  }

  /**
   * 当前「吧主页默认进入界面」档位：0 = 热门（默认）/ 1 = 最新。
   * 真源为 AppStorage（吧主页 ThreadList aboutToAppear 直读），manager 只负责冷启动恢复与落盘。
   */
  getForumDefaultSort(): number {
    return UsageHabitsManager.normalizeForumSort(AppStorage.get<number>('forumDefaultSort'));
  }

  /** 「吧主页默认进入界面」档位归一：0 = 热门 / 1 = 最新 / 2 = 精选（越界回退 0） */
  static normalizeForumSort(raw: string | number | undefined | null): number {
    const n: number = Number.parseInt(`${raw ?? 0}`, 10);
    return (n >= 0 && n <= 2) ? n : 0;
  }

  /** 设置「吧主页默认进入界面」档位：立即更新 AppStorage 并落盘。 */
  async setForumDefaultSort(mode: number): Promise<void> {
    const v: number = UsageHabitsManager.normalizeForumSort(mode);
    AppStorage.setOrCreate('forumDefaultSort', v);
    await this.persistForumDefaultSort(v);
  }

  private async persistForumDefaultSort(mode: number): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.FORUM_DEFAULT_SORT, `${mode}`);
    } catch (e) {
      // 忽略持久化错误
    }
  }

  /** 「楼中楼回复字号」整体缩放比例（0.7~1.2，缺省 0.9），真源 AppStorage，manager 负责冷启恢复与落盘 */
  getSubReplyScale(): number {
    const v: number = AppStorage.get<number>('subReplyScale') ?? 0.9;
    return (v < 0.7 || v > 1.2) ? 0.9 : v;
  }

  /** 设置「楼中楼回复字号」缩放：立即更新 AppStorage 并落盘。 */
  async setSubReplyScale(scale: number): Promise<void> {
    const v: number = (scale < 0.7 || scale > 1.2) ? 0.9 : scale;
    AppStorage.setOrCreate('subReplyScale', v);
    await this.persistSubReplyScale(v);
  }

  private async persistSubReplyScale(scale: number): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.SUB_REPLY_SCALE, `${scale}`);
    } catch (e) {
      // 忽略持久化错误
    }
  }

  /**
   * 顶栏渐变模糊的半径（vp），范围 0~60。
   * 真源为 AppStorage('tbx_blur')，TopBarFx 直读；manager 只负责冷启恢复与落盘。
   */
  static normalizeTopBlur(raw: string | number | undefined | null): number {
    const n: number = Number.parseFloat(`${raw ?? ''}`);
    if (isNaN(n)) {
      return TopBarFx.DEFAULT_BLUR;
    }
    return Math.max(0, Math.min(TopBarFx.MAX_BLUR, n));
  }

  /** 实心模糊段结束位置。模糊开启时须小于渐退段。 */
  static normalizeTopSolid(raw: string | number | undefined | null): number {
    const n: number = Number.parseFloat(`${raw ?? ''}`);
    if (isNaN(n)) {
      return TopBarFx.DEFAULT_SOLID;
    }
    return Math.max(0, Math.min(0.9, n));
  }

  /** 渐退段结束位置，0 表示关闭渐变模糊。 */
  static normalizeTopFade(raw: string | number | undefined | null): number {
    const n: number = Number.parseFloat(`${raw ?? ''}`);
    if (isNaN(n)) {
      return TopBarFx.DEFAULT_FADE;
    }
    return n <= 0 ? 0 : Math.max(0.02, Math.min(1, n));
  }

  getTopBarBlur(): number {
    return UsageHabitsManager.normalizeTopBlur(AppStorage.get<number>('tbx_blur'));
  }

  getTopBarSolid(): number {
    return UsageHabitsManager.normalizeTopSolid(AppStorage.get<number>('tbx_solid'));
  }

  getTopBarFade(): number {
    return UsageHabitsManager.normalizeTopFade(AppStorage.get<number>('tbx_fade'));
  }

  /**
   * 设置顶栏模糊参数：写 AppStorage 并落盘，同时递增 topBarFxTick 广播。
   * 因为 fuzzy 半径 / fractionStops 是 build 期读值，仅改 AppStorage 不会触发重绘；
   * 各页以 @StorageLink('topBarFxTick') 把 tick 传进 TopBarFx.xxx(tick) 建立构建期依赖，
   * 改任一项即全局重绘，返回其它页面立即可见。
   * 渐退段为 0 时将实心段归零。开启时保持渐退段位于实心段之后。
   */
  async setTopBarFx(blur: number, solid: number, fade: number): Promise<void> {
    const b: number = UsageHabitsManager.normalizeTopBlur(blur);
    let f: number = UsageHabitsManager.normalizeTopFade(fade);
    const s: number = f === 0 ? 0 : UsageHabitsManager.normalizeTopSolid(solid);
    if (f > 0 && f <= s) {
      f = s + 0.02;
    }
    AppStorage.setOrCreate('tbx_blur', b);
    AppStorage.setOrCreate('tbx_solid', s);
    AppStorage.setOrCreate('tbx_fade', f);
    AppStorage.setOrCreate('topBarFxTick', (AppStorage.get<number>('topBarFxTick') ?? 0) + 1);
    await this.persistTopBarFx(b, s, f);
  }

  /** 恢复顶栏模糊参数为默认值。 */
  async resetTopBarFx(): Promise<void> {
    await this.setTopBarFx(TopBarFx.DEFAULT_BLUR, TopBarFx.DEFAULT_SOLID, TopBarFx.DEFAULT_FADE);
  }

  private async persistTopBarFx(blur: number, solid: number, fade: number): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.TOP_BAR_BLUR, `${blur}`);
      await cache.put(CACHE_KEY.TOP_BAR_SOLID, `${solid}`);
      await cache.put(CACHE_KEY.TOP_BAR_FADE, `${fade}`);
    } catch (e) {
      // 忽略持久化错误
    }
  }

  /**
   * 「卡片圆角」整体缩放比例为 0~2，0 为直角。
   * 真源 AppStorage('cardRadiusScale')，各卡片组件以 @StorageLink 直读实现实时重绘；
   * manager 只负责冷启恢复与落盘。
   */
  static normalizeCardRadiusScale(raw: string | number | undefined | null): number {
    const n: number = Number.parseFloat(`${raw ?? ''}`);
    if (isNaN(n)) {
      return DEFAULT_CARD_RADIUS_SCALE;
    }
    return Math.max(0, Math.min(2, n));
  }

  getCardRadiusScale(): number {
    return UsageHabitsManager.normalizeCardRadiusScale(AppStorage.get<number>('cardRadiusScale'));
  }

  /** 设置「卡片圆角」缩放：立即更新 AppStorage（全站卡片圆角实时生效）并落盘。 */
  async setCardRadiusScale(scale: number): Promise<void> {
    const v: number = UsageHabitsManager.normalizeCardRadiusScale(scale);
    AppStorage.setOrCreate('cardRadiusScale', v);
    await this.persistCardRadiusScale(v);
  }

  /** 恢复「卡片圆角」缩放为默认值。 */
  async resetCardRadiusScale(): Promise<void> {
    await this.setCardRadiusScale(DEFAULT_CARD_RADIUS_SCALE);
  }

  private async persistCardRadiusScale(scale: number): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.CARD_RADIUS_SCALE, `${scale}`);
    } catch (e) {
      // 忽略持久化错误
    }
  }

  /**
   * 「最近进入」吧头像大小为 0~72 vp，步进 2，0 时只显示吧名。
   * 真源 AppStorage('recentAvatarSize')，进吧页 ForumsTab 以 @StorageLink 直读实时重绘；
   * manager 只负责冷启恢复与落盘。
   */
  static normalizeRecentAvatarSize(raw: string | number | undefined | null): number {
    const n: number = Number.parseFloat(`${raw ?? ''}`);
    if (isNaN(n)) {
      return DEFAULT_RECENT_AVATAR_SIZE;
    }
    return Math.max(0, Math.min(72, Math.round(n)));
  }

  getRecentAvatarSize(): number {
    return UsageHabitsManager.normalizeRecentAvatarSize(AppStorage.get<number>('recentAvatarSize'));
  }

  /** 设置「最近进入」吧头像大小：立即更新 AppStorage（进吧页实时生效）并落盘。 */
  async setRecentAvatarSize(size: number): Promise<void> {
    const v: number = UsageHabitsManager.normalizeRecentAvatarSize(size);
    AppStorage.setOrCreate('recentAvatarSize', v);
    await this.persistRecentAvatarSize(v);
  }

  /** 恢复「最近进入」吧头像大小为默认值。 */
  async resetRecentAvatarSize(): Promise<void> {
    await this.setRecentAvatarSize(DEFAULT_RECENT_AVATAR_SIZE);
  }

  private async persistRecentAvatarSize(size: number): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.RECENT_AVATAR_SIZE, `${size}`);
    } catch (e) {
      // 忽略持久化错误
    }
  }

  private async persistDarkMode(enabled: boolean): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.DARK_MODE, enabled ? '1' : '0');
    } catch (e) {
      // 忽略持久化错误
    }
  }

  private async persistImmersiveRead(enabled: boolean): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.IMMERSIVE_READ, enabled ? '1' : '0');
    } catch (e) {
      // 忽略持久化错误
    }
  }

  private async persistImmersiveReadExtra(enabled: boolean): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.IMMERSIVE_READ_EXTRA, enabled ? '1' : '0');
    } catch (e) {
      // 忽略持久化错误
    }
  }

  private async persistFollowSystemDark(enabled: boolean): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.FOLLOW_SYSTEM_DARK, enabled ? '1' : '0');
    } catch (e) {
      // 忽略持久化错误
    }
  }

  /**
   * 当前是否已「关闭自动旋转」。默认 false（允许旋转），保持既有行为零回归。
   */
  isAutoRotateOff(): boolean {
    return AppStorage.get<boolean>('autoRotateOff') ?? false;
  }

  /**
   * 设置「关闭自动旋转」：立即更新 AppStorage、落盘，并**即时下发窗口方向**。
   * 即时下发不可省：宿主只在冷启动 onWindowStageCreate 下发过一次方向，不补发就得杀进程重进才生效。
   */
  async setAutoRotateOff(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('autoRotateOff', enabled);
    this.persistAutoRotate(enabled).catch(() => {
    });
    applyAutoRotateOff(enabled);
  }

  private async persistAutoRotate(enabled: boolean): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.AUTO_ROTATE, enabled ? '1' : '0');
    } catch (e) {
      // 忽略持久化错误
    }
  }
}

/**
 * 按「关闭自动旋转」开关下发窗口方向（模块级：不依赖 manager 实例，宿主与页面可共用）。
 * - 守卫：仅阔直屏直板（isWideBarFlatDevice()）真下发。该开关只对阔直屏显示；其余形态
 *   （Pura X、Pura X Max 展开、大折叠展开、平板、普通手机）若被误调一律直接 return，
 *   绝不把不该锁的设备锁成竖屏。
 * - 关闭 = PORTRAIT（显式锁竖屏，而非「不干预」）：阔直屏走 module.json5 默认 unspecified
 *   跟随系统开关，用户系统开关若为开，不干预等于开关无效。
 * - 未关闭 = AUTO_ROTATION（回到既有的主动解锁）。
 * - mainWindow 未就绪时静默跳过：冷启动首帧方向由 EntryAbility 同步读 prefs 兜住。
 */
export function applyAutoRotateOff(off: boolean): void {
  try {
    if (!isWideBarFlatDevice()) {
      return;
    }
    const mainWindow: window.Window | undefined = AppStorage.get<window.Window>('mainWindow');
    if (!mainWindow) {
      return;
    }
    mainWindow.setPreferredOrientation(off
      ? window.Orientation.PORTRAIT
      : window.Orientation.AUTO_ROTATION)
      .catch((err: Error) => {
        hilog.error(0x0000, TAG, 'setPreferredOrientation(autoRotateOff=%{public}s) failed: %{public}s',
          off ? '1' : '0', JSON.stringify(err));
      });
  } catch (e) {
    hilog.error(0x0000, TAG, 'applyAutoRotateOff failed: %{public}s', JSON.stringify(e));
  }
}
