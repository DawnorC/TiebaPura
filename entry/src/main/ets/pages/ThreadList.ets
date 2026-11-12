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

import { bundleManager, common, Want } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { pasteboard, BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { display, curves, componentSnapshot, LengthMetrics, RectShape } from '@kit.ArkUI';
import { FixedPageBars } from '../components/FixedPageBars';
import { image } from '@kit.ImageKit';
import { effectKit } from '@kit.ArkGraphics2D';
import { http } from '@kit.NetworkKit';
import { TiebaService, ForumSignStatus, ThreadDetailResult, HOT_RANK_PAGES } from '../service/TiebaService';
import { ForumSignStore } from '../service/ForumSignStore';
import { ThreadItem, ForumHeaderInfo, ForumSearchData, ThreadDetail, PagedResult } from '../model/DataModel';
import {
  Theme, Spacing, Radius, Breakpoint, CARD_COLUMNS_KEY, isDarkMode, ImmBlur, ImmMaterial, MaterialManager,
  fs, isWideBarDevice, isLargeFoldDevice, isWideFormDevice as detectWideFormDevice, readColumnMode,
  overrideColumns, isLargeScreenForm, isWideBarFullscreen,
  DEFAULT_PAGE_MARGIN, DEFAULT_CARD_RADIUS_SCALE, FORUM_CARD_RADIUS_BASE
} from '../common/Theme';
import { CacheManager } from '../cache/CacheManager';
import { HistoryStore } from '../service/HistoryStore';
import { CACHE_KEY, CACHE_TTL } from '../common/Constants';
import { Haptic } from '../common/Haptic';
import { PrefetchGate } from '../common/PrefetchGate';
import {
  ImmersiveReadSensor, IMMERSIVE_EXTRA_FLY_SCALE, IMMERSIVE_EXTRA_HIDE_MS, IMMERSIVE_EXTRA_SHOW_MS,
  IMMERSIVE_EXTRA_SPRING_RESPONSE, IMMERSIVE_EXTRA_SPRING_DAMPING
} from '../common/ImmersiveReadSensor';
import {
  LoadingView, EmptyView, ErrorView, ThreadCard, ThreadItemData, ThreadSharePayload, PinnedThreadItem, openForumImagePreview
} from '../components/CommonComponents';
import { ThreadListSkeleton } from '../components/Skeleton';
import { PerfTrace } from '../common/PerfTrace';

import { TopBarFx } from '../components/TopBarFx';
import { TopGlassVeil } from '../components/TopGlassVeil';
enum LoadState {
  Loading, Success, Empty, Error,
}

/** 吧主页预加载阈值：距底部剩余距离小于该值时提前静默加载下一页（约 2 屏，覆盖快速甩滑的请求耗时） */
const THREAD_PREFETCH_DISTANCE: number = 1200;
/**
 * 尾部加载提示延迟（ms）：后台预取路径**先静默**（不显形、不转圈），超过该时长仍未返回才浮出 loading ——
 * 绝大多数请求 300~600ms 返回，用户永远看不到"正在加载"。口径同 ThreadDetail.DETAIL_LOAD_HINT_DELAY。
 */
const LIST_LOAD_HINT_DELAY: number = 1200;
/** 尾部哨兵固定高度（vp）：静默占位 / 加载中 / 加载失败重试三态等高，追加内容时视口零位移 */
const LIST_FOOTER_SENTINEL_H: number = 40;

/**
 * 本吧搜索扫描参数（BUG-03 后续优化）：
 * 无可用服务端吧内搜索接口，故为「本地扫描吧内分页 + 标题/摘要匹配」，结果量取决于扫了多少页。
 * SEARCH_DEBOUNCE_MS   输入防抖，避免逐字各触发一轮扫描；
 * SEARCH_CONCURRENCY   单轮并发页数（并行抓取替代逐页串行——"加载慢"的主因之一）；
 * SEARCH_BATCH_RESULTS 单批目标结果数（凑够约 8 屏再交给滚动，取代"每次触底才多一条"）；
 * SEARCH_BATCH_PAGES   单批最多扫描页数（继续下滑再补下一批，防超大吧单次等待过久）；
 * SEARCH_SCAN_SORT     扫描固定用「热门」序（与当前排序 Tab 无关）：否则在「精选」Tab 下
 *                      只能扫到精品帖，结果必然少得可怜。
 */
const SEARCH_DEBOUNCE_MS: number = 300;
const SEARCH_CONCURRENCY: number = 3;
const SEARCH_BATCH_RESULTS: number = 40;
const SEARCH_BATCH_PAGES: number = 12;
const SEARCH_SCAN_SORT: number = 0;
/** 服务端吧内搜索每页条数（一次请求即整屏，替代逐页扫描） */
const SEARCH_SERVER_PAGE_SIZE: number = 30;
/** 服务端结果自动续载上限（条）：防 has_more 异常时后台无限翻页，超出后仅由用户下滑驱动 */
const SEARCH_SERVER_AUTO_MAX: number = 300;
/**
 * 服务端搜索结果补数据的并发数：/c/s/searchpost 只给 tid/pid/title/content/time/fname/author{name,name_show}，
 * 缺 authorId（点作者不跳转）、头像（降级为字母）、回复数/点赞数（恒为 0），故按 tid 拉详情补齐。
 * 详情接口与点开帖子同源且带缓存，并发 3 兼顾补齐速度与风控。
 */
const SEARCH_ENRICH_CONCURRENCY: number = 3;
/** 本地扫描硬上限（页）：防超大吧在后台无限扫描（约 1600 帖），到顶即停止并如实提示 */
const SEARCH_SCAN_MAX_PAGES: number = 80;
/** 自动续载延迟：给 UI 一帧渲染机会再取下一批 */
const SEARCH_AUTO_CONTINUE_MS: number = 120;

// 官方贴吧（鸿蒙版）包名与市场页：吧主页跳转仅携带吧名 kw，不含任何登录态参数
// （与 ThreadDetail 同源；帖子里用的是 wapp 域直达，官方声明的 skills 不匹配 tieba.baidu.com）
const TIEBA_OFFICIAL_BUNDLE: string = 'com.baidu.tiebaapp';
const TIEBA_MARKET_URL: string = 'https://appgallery.huawei.com/app/detail?id=com.baidu.tiebaapp';

/**
 * 排序 tab 切换（热门 / 最新 / 精选）——**照搬首页 `Index.switchTab` 的「两页连着」过场**：
 * 数据就位的那一帧，新内容自对侧整屏（±100%）进入，**旧内容同时向反侧整屏滑出**，二者在同一个
 * `animateTo`（320ms / `springMotion(0.72, 0.86)`）里对向平移 —— 屏幕上任一瞬间都是"两页相接在移动"，
 * 这正是首页 5 个 Tab 切页那种"仿佛两个界面连在一起"的顺滑感来源。
 *
 * 演进（三次真机反馈，教训都留在这里）：
 *   ① 单侧滑入 120 / 300ms `FastOutSlowIn` → 起点慢、收尾也慢，被判"生硬"；
 *   ② 「退场 + 入场」双拍（130ms 反向退场 + 微缩 + 淡到 0.25 + 140vp 入场）→ 被判**"太过度、中间还会卡一下"**：
 *      过度来自位移幅度与叠在一起的三类变化（位移 / 透明度 / 缩放），卡顿来自两拍之间的等待帧
 *      （退场播完到入场播放之间内容静止约 160ms）与入场前的强制停帧（24ms）；
 *   ③ 收缩为"只有新页滑入"的一段式（100vp）→ 被判"变回生硬"：**旧页不动、被瞬间替换掉**，
 *      本质只是"一块内容换成另一块"，缺少两页相接的连续感；
 *   ④ 现按首页原样复刻：新页 ±100%、旧页反向 ±100%、同一个 `animateTo` —— **关键在旧页不消失**。
 *
 * 「旧页画面」从哪来：首页每页都是常驻组件（`visibility` 隐藏、切页只改位移），所以旧页天然在树上；
 * 本页只有一个列表、数据在切换那一刻被整体替换，旧内容无处可寻，故在**点击那一刻**
 * 用 `componentSnapshot.getSync`（同步）截下列表区（旧内容 + 旧滚动位置，吧头由 region 裁掉）存为 PixelMap，
 * 由一层 `Image` 承载滑出，动画收口后释放。同步截图取的是上一帧已渲染的成品，不阻塞布局、
 * 不引入等待帧、也不改变任何现有几何。
 *
 * 「平移作用域 = 只到列表区，吧头 / 顶栏 / 底栏静止」（2026-09-12 真机反馈后的调整）：
 *   位移原挂在 Scroll 上，而吧头（吧名 / 头像 / 关注签到）是 Scroll 内容里的普通子项，于是**吧头被一起带着滑**；
 *   首页切 Tab 时标题栏与底栏都是静止的，只有内容页对向平移 —— 两者观感不一致。现改为：
 *   ① 新页位移缩到 Scroll 内的「列表区」那一层（内容 / 骨架屏 / 空态 / 错误），吧头与兜底排序栏不参与位移；
 *   ② 旧页快照用 `SnapshotOptions.region`（单位 px，API 15+）裁掉吧头、只留列表区，快照层再按裁剪量下移到
 *      列表区位置 —— 屏幕上于是"吧头原地不动、只有下方列表对向平移"，与首页头部固定、内容平移同构；
 *   ③ 吧头已滚出屏幕上方（或高度尚未测到）时不裁：整屏即列表内容，行为与调整前一致，属自动降级。
 *   注意：只做水平位移、垂直位置不动，故列表区不会与静止的吧头在几何上重叠。
 */
const SORT_ANIM_DURATION: number = 320;     // 对向平移时长（ms）：与首页 Tab 切换同值
const SORT_ANIM_SETTLE: number = 420;       // 动画收口时刻（≈时长的 1.3 倍）：卸载旧页快照 + 复位位移
const SORT_SKELETON_FADE: number = 150;     // 未命中缓存时骨架屏淡入时长（ms，不与滑入叠加）
/** 内容滚动容器 id：`componentSnapshot` 按它截取旧页（见上方 SORT_ANIM_* 注释） */
const THREAD_SCROLL_SNAPSHOT_ID: string = 'threadListScrollSnapshot';

/**
 * 吧主页官方槽位开关（§6.10 模板）：true 且设备支持材质时，顶栏整行（返回 / 搜索框 / 搜索钮 / 更多钮）
 * 搬进 Navigation title 槽位吃官方沉浸材质；false 或低版本自动回退到页面主体悬浮自绘玻璃（改造前原样）。
 */
const THREAD_LIST_OFFICIAL_TITLE_BAR: boolean = true;

/**
 * 单列档（手机）滚动容器：Scroll + Column 全量渲染 + 窗口化挂载 → WaterFlow('1fr') + LazyForEach。
 * 与首页 HomeTab（v1.0.8）同方案，依据同一批真机实测：窗口化挂载每次推进 = 一帧 30~60ms
 * （固定 ~15~20ms 整列重排 + ~4.5ms/张组件构建，与模糊/图片无关），滑动中表现为周期性抽搐。
 * 本页的差异点（勿照抄首页，也勿混多列档）：
 *   ① **不挂 WaterFlowSections** —— 单列吧头本就全宽，作为普通格子即可；避开 2026-09-24
 *      「跨 section 单列虚拟化真机整层不渲染」的既有结论（多列档仍必须走 sections）；
 *   ② rowsGap 置 0，卡距由卡片自身 margin.bottom(6) 承担 —— 让「置顶合并块的让位格子」不产生间距；
 *   ③ 置顶仍以**合并卡片**呈现（一个 bgCard 内装「置顶」标签 + 全部置顶帖）：由数据源首个置顶项
 *      渲染整块，其余置顶项渲染 0 高占位。
 * 置 false 即一行回退到原 Scroll + 窗口化挂载路径（两条路径都保留在 build 内）。
 */
const THREAD_LIST_SINGLE_WATERFLOW: boolean = true;
/** 槽位高度 = 44(状态栏让位) + 44(钮行高) + 10(底部呼吸)，与改造前悬浮顶栏 padding 逐项一致；
 *  内容让位（Scroll 首项占位 90）一行未改。 */
const THREAD_LIST_TITLE_BAR_HEIGHT: number = 98;
const FORUM_REFRESH_MAX_PULL: number = 96;
const FORUM_HEADER_SNAP_TOLERANCE: number = 0.5;
const FORUM_HEADER_FLICK_SPEED: number = 450; // vp/s

/** 多列吧头经验条宽度上限。 */
const THREAD_LIST_EXP_BAR_MAX_WIDTH: number = 220;
const THREAD_SEARCH_COL_BALANCE_THRESHOLD: number = 240;
/** 系统弹窗宽度默认上限（vp）：平板 / 折叠展开下「屏幕宽 - 48」可达 900+vp 把弹窗拉成通栏，故显式封顶 */
const THREAD_LIST_DIALOG_MAX_WIDTH: number = 400;
/** 列表底部让位（槽位路径）：加号钮顶 86（底距 30 + 56）+ 12 呼吸 = 98
 *  （刷新钮移除后最高点由刷新钮退回加号，故比原值 166 少 68、比更早的 244 少 146，
 *    列表可视区同步变大）。 */
// 左右滑切排序：滑动结束后延时解锁卡点按（GoodCategoryPage 同款，覆盖手势收尾的 click 派发窗口）
const THREAD_LIST_SWIPE_UNLOCK_DELAY: number = 250;
// 左右滑切排序的最小位移阈值（vp），与 HomeTab 推荐流同档
const THREAD_LIST_SWIPE_SWITCH_THRESHOLD: number = 80;

/** 吧列表本地快照（含吧头信息），命中缓存即秒开再后台静默刷新 */
interface ForumListCache {
  threads: ThreadItem[];
  forumInfo: ForumHeaderInfo | null;
  page?: number;
  hasMore?: boolean;
}

/**
 * 页内会话排序快照：本次进吧期间展示过的排序数据 + 分页状态。
 * 切回该排序且未超 SORT_SESSION_TTL 时 0 开销直出（免 Preferences 读盘、免重复网络刷新）。
 */
interface SortSession {
  threads: ThreadItem[];
  page: number;
  hasMore: boolean;
  ts: number;
}

/** 排序会话快照保鲜期：期间内切回已看过的排序直接秒开 */
const SORT_SESSION_TTL: number = 120000;

/**
 * 排序切换「上屏」数据包：`applySortDisplay` 的统一入参 —— 数据来源（页内快照 / 本地缓存 / 网络）
 * 不同，但「替换 + 回顶 + 起滑」这套上屏动作完全一致。
 * `sort` 用于竞态校验：快速连点时丢弃不属于当前排序的迟到数据。
 */
interface SortDisplay {
  /** 数据归属键（= sortKey()）：热门为 'hot'（客户端热度榜），其余为生效排序号字符串 */
  key: string;
  threads: ThreadItem[];
  page: number;
  hasMore: boolean;
  /** Success / Empty = 直接上屏播入场；Loading = 未命中缓存，落骨架屏等网络 */
  state: LoadState;
}

/**
 * 吧主页右上角「更多」操作面板（系统 CustomDialog + API 26 沉浸光感）。
 *
 * 为什么从「自绘浮层」改成系统弹窗：官方沉浸光感的 A 档「弹窗类」只覆盖系统 Dialog /
 * 弹窗类接口（CustomDialogControllerOptions、AlertDialogParam、ActionSheetOptions、
 * SheetOptions、PromptAction 等）；页面 body 内的自绘 Stack 浮层不在生效范围内，
 * 挂 systemMaterial 必然判 `Material inactive: out of scope`（工程文档 §1.2 / §8 已证实）。
 *
 * 几何与内容对齐（与改造前的自绘浮层逐项一致）：
 * - 宽度 calc(100% - 48vp) → options.width 数值 vp；圆角 32vp；遮罩 #06000000；
 *   底部锚点（底距 30，即「小白条」上沿的悬浮基线）；标题行 / 菜单行 / 分隔线 / 取消按钮
 *   尺寸与字号全部原样保留。
 *
 * 玻璃层由宿主的 options.systemMaterial 承担（材质会接管容器的背景色 / 背景模糊 / 边框 / 阴影），
 * 因此卡内不再自绘 backgroundColor / backgroundBlurStyle / border / shadow 这四项；
 * 卡内「取消」按钮是例外 —— 按钮自身挂材质时半透明底色 + 自定义轻投影可与材质共存（文档 §6.2）。
 */
@CustomDialog
struct ForumMoreDialogCard {
  @StorageLink('cardRadiusScale') cardRadiusScale: number = DEFAULT_CARD_RADIUS_SCALE;
  /** 系统弹窗必须声明 CustomDialogController 类型属性（ArkTS 编译期强校验） */
  controller?: CustomDialogController;
  @Link isDark: boolean;
  @Link fontScale: number;
  /** 吧名（宿主 forumName 直接双向绑定） */
  @Link forumName: string;
  /** 打开那一刻是否已关注（决定菜单文案与图标；快照由宿主在打开前同步） */
  @Link liked: boolean;
  /** 分享吧 */
  onShare: () => void = () => {};
  /** 关注 / 取消关注 */
  onToggleFollow: () => void = () => {};
  /** 取消 / 点遮罩 / 返回键 */
  onDismiss: () => void = () => {};

  build() {
    Column({ space: 0 }) {
      // 标题行：吧名 + 已关注标签
      Row({ space: 8 }) {
        Text(this.forumName)
          .fontSize(fs(17, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.liked) {
          Text('已关注')
            .fontSize(fs(11, this.fontScale))
            .fontColor(Theme.brand())
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(Radius.full)
            .backgroundColor(Theme.brandBg(this.isDark))
        }
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.lg, bottom: Spacing.sm })

      // 分享吧
      Row({ space: Spacing.md }) {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontSize(fs(19, this.fontScale))
          .fontColor([Theme.textPrimary(this.isDark)])
        Text('分享吧')
          .fontSize(fs(15, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, top: 12, bottom: 12 })
      // 圆角 26：与全局卡片统一口径（本行无填充底，圆角当前不可见，仅保持令牌一致）
      .borderRadius(26 * this.cardRadiusScale)
      .accessibilityText('分享吧')
      .onClick(() => { this.onShare(); })

      Column()
        .width('calc(100% - 32vp)')
        .height(0.5)
        .backgroundColor(this.isDark ? '#26FFFFFF' : '#12000000')

      // 关注 / 取消关注（状态跟随打开时的快照，取消关注为危险操作）
      Row({ space: Spacing.md }) {
        SymbolGlyph($r(this.liked ? 'sys.symbol.heart_fill' : 'sys.symbol.heart'))
          .fontSize(fs(19, this.fontScale))
          .fontColor([this.liked ? Theme.danger() : Theme.textPrimary(this.isDark)])
        Text(this.liked ? '取消关注' : '关注')
          .fontSize(fs(15, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.liked ? Theme.danger() : Theme.textPrimary(this.isDark))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, top: 12, bottom: 12 })
      // 圆角 26：与全局卡片统一口径（本行无填充底，圆角当前不可见，仅保持令牌一致）
      .borderRadius(26 * this.cardRadiusScale)
      .accessibilityText(this.liked ? '取消关注' : '关注')
      .onClick(() => { this.onToggleFollow(); })

      Button() {
        Text('取消')
          .fontSize(fs(15, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
      }
      .width('100%')
      .height(44)
      .margin({ top: Spacing.sm })
      // 与一键签到 / 吧菜单弹窗的次按钮同源：材质 + 半透明底 + 中性轻投影
      // （底色不透明会完全盖掉材质滤镜，故必须带透明度，见文档 §6.2 / 坑 11）
      .systemMaterial(ImmMaterial.cardAction())
      .backgroundColor(this.isDark ? '#B31B1E24' : '#B3FFFFFF')
      .borderRadius(Radius.full)
      .shadow({ radius: 10, color: this.isDark ? '#4D000000' : '#1F101824', offsetY: 3 })
      .accessibilityText('取消')
      .onClick(() => { this.onDismiss(); })
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.lg })
  }
}

/**
 * 跳转官方吧主页确认弹窗（系统 CustomDialog + API 26 沉浸光感）。
 *
 * 页内复刻 ThreadDetail 的 JumpTiebaDialogCard（2026-09-14）：几何 / 材质 / 按钮样式逐项一致，
 * 仅文案换成吧主页语境（用户指定标题「确认是否跳转官方吧主页」）。ThreadDetail 原件一行未动。
 * 数据传递：链接预览走 @Link 快照 —— forumAppUrl() 是宿主方法，弹窗内取不到。
 */
@CustomDialog
struct ForumJumpDialogCard {
  /** 系统弹窗必须声明 CustomDialogController 类型属性（ArkTS 编译期强校验） */
  controller?: CustomDialogController;
  @Link isDark: boolean;
  @Link fontScale: number;
  /** 目标链接预览（宿主在打开前算好并写入） */
  @Link targetUrl: string;
  /** 确定：拉起官方贴吧（业务全在宿主 confirmJump，弹窗只负责回调） */
  onConfirm: () => void = () => {};
  /** 取消 / 点遮罩 / 返回键（同源，宿主 onWillDismiss 与取消钮共用） */
  onDismiss: () => void = () => {};

  build() {
    Column() {
      // 标题 + 说明 + 目标链接预览
      Column({ space: 6 }) {
        Text('确认是否跳转官方吧主页')
          .fontSize(fs(17, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
          .textAlign(TextAlign.Center)
        Text('将在官方贴吧中打开本吧（仅携带吧名，不含登录信息）')
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .lineHeight(fs(18, this.fontScale))
          .textAlign(TextAlign.Center)
        Text(this.targetUrl)
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.lg, bottom: Spacing.md })

      // 确定 / 取消（竖排全宽，与 ThreadDetail 弹窗逐项一致）
      Column({ space: Spacing.sm }) {
        Button() {
          Text('确定')
            .fontSize(fs(15, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
        }
        .width('100%')
        .height(44)
        // 品牌蓝主按钮：材质 + 半透明底 + 同色浮起阴影（与 ThreadDetail / 收藏页确认弹窗同源）
        .systemMaterial(ImmMaterial.accent(this.isDark))
        .backgroundColor('#CC3173FF')
        .borderRadius(Radius.full)
        .shadow({
          radius: 14,
          color: this.isDark ? '#663173FF' : '#4D3173FF',
          offsetY: 4
        })
        .accessibilityText('确认跳转官方吧主页')
        .onClick(() => { this.onConfirm(); })

        Button() {
          Text('取消')
            .fontSize(fs(15, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
        }
        .width('100%')
        .height(44)
        // 次按钮：材质 + 半透明底 + 中性轻投影（底色不透明会盖掉材质）
        .systemMaterial(ImmMaterial.cardAction())
        .backgroundColor(this.isDark ? '#B31B1E24' : '#B3FFFFFF')
        .borderRadius(Radius.full)
        .shadow({ radius: 10, color: this.isDark ? '#4D000000' : '#1F101824', offsetY: 3 })
        .accessibilityText('取消跳转')
        .onClick(() => { this.onDismiss(); })
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.lg })
    }
    .width('100%')
    .padding({ top: Spacing.md })
  }
}

/**
 * 吧内帖子列表 WaterFlow 数据源（§4.8 决策 13）：把「置顶卡 + 普通帖」合并为一个列表，
 * 通过 `threads` 的 `@Watch('onThreadsChanged')` 自动同步。
 * 通过批量变更通知 LazyForEach，分页时一次登记整批新增卡片。
 */
class ThreadListDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  public data: ThreadItem[] = [];

  totalCount(): number {
    return this.data.length;
  }

  getData(index: number): ThreadItem {
    return this.data[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  notify(operations: DataOperation[]): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDatasetChange(operations);
    });
  }
}

@Entry
@Component
struct ThreadList {
  @StorageLink('cardRadiusScale') cardRadiusScale: number = DEFAULT_CARD_RADIUS_SCALE;
  @StorageLink('topBarFxTick') tbxTick: number = 0;
  // 「左右留白」设置：驱动吧内帖子卡两侧留白（cardSideInset），变化时重算多列主体 section margin
  @StorageLink('pageMargin') @Watch('onPageMarginChange') pageMargin: number = DEFAULT_PAGE_MARGIN;
  @State forumName: string = '';
  @State forumId: string = '';
  @State @Watch('onThreadsChanged') threads: ThreadItem[] = [];
  // 页内会话排序快照：切走再切回同一排序时 0 开销秒开（免 Preferences 读盘 + 免重复网络刷新）。
  // key = sortKey()（'hot' / '0' / '1' / '2'）：热门档与「最新·按回复时间」同为 sort_type 0 但内容集不同，
  // 必须用不同键，否则两者会互相命中对方的快照（旧实现直接用 effectiveSort() 数字，正是这个隐患）。
  private sortSession: Map<string, SortSession> = new Map<string, SortSession>();
  // 排序预热标记：首次成功展示后后台把其它两个排序的冷缓存拉好，使首次切换即命中
  private warmupStarted: boolean = false;
  @State @Watch('onLoadStateChanged') loadState: LoadState = LoadState.Loading;
  @State errorMsg: string = '';
  @State page: number = 1;
  @State hasMore: boolean = true;
  @State loadingMore: boolean = false;
  @State stalledPages: number = 0;
  // 吧主页预加载：测量值 + 节流/竞态（普通字段，避免高频回调触发 UI 重建）
  private contentH: number = 0;
  private viewportH: number = 0;
  /** 视口宽（vp）：仅旧页快照的 region 需要（region 四边单位是 px，见 captureExitSnapshot） */
  private viewportW: number = 0;
  /** 吧头块实测高（vp）= 吧头（+ 兜底排序栏）那一层，由渲染层 onAreaChange 回填。
   *  旧页快照的裁剪边界由它推出；未测到（≤ 0）时不裁、自动降级回调整前的整屏裁剪行为 */
  private headerBlockH: number = 0;
  /**
   * 剩余距离预取闸门（2026-09-19 口径修正）：滚动偏移只信 `Scroller.currentOffset()`，
   * 不再用 `onScroll` 回调入参（其语义在工具链间有差异，会把剩余距离算成恒小于阈值的错值，
   * 表现为「每滚一下都翻页」或「滑到底空一段才加载」）。单列档内容高由 onContentAreaChange 实测；
   * 多列档 WaterFlow 无内容总高接口 → 折算（见 listContentH / estimatedColumnContentH）。
   */
  private prefetchGate: PrefetchGate = new PrefetchGate(THREAD_PREFETCH_DISTANCE, 'ThreadList');
  /** 尾部加载提示是否浮出：后台预取路径超时才置 true；用户显式触底立即置 true（口径同 ThreadDetail） */
  @State loadingHintVisible: boolean = false;
  /** 尾部加载失败态：仅用户显式路径置位（后台预取失败保持静默，由触底兜底重试） */
  @State loadMoreFailed: boolean = false;
  /** 尾部提示延时器句柄（setTimeout 返回值，-1 = 空闲）：退页时必须清理，防回调落到已销毁组件 */
  private loadingHintTimer: number = -1;
  /** 几何来源探针是否已打印（每会话仅一条）：真机自证「内容高是实测还是折算、折算参数是多少」 */
  private contentSrcNoted: boolean = false;
  private loadToken: number = 0;
  private lastPrefetchPage: number = -1;
  @State selectedSort: number = 0;
  /**
   * 「最新」档内的子排序：0 = 按回复时间（sort_type 0，服务端默认序）/ 1 = 按发帖时间（sort_type 1）。
   * 缺省 1 = 改造前「最新」档的固定参数，老用户零回归；点选即持久化（CACHE_KEY.LATEST_SORT_MODE，全局档）。
   * 仅「最新」档生效：热门（0）/ 精选（2）不读本值。
   */
  @State latestSortMode: number = 1;
  /** 「最新」档顶栏排序钮的 bindMenu 显隐（点选即关，onDisappear 兜底复位） */
  @State pinnedExpanded: boolean = false;
  @State forumHeaderBodyH: number = 0;
  @State forumHeaderOffset: number = 0;
  @State forumPullOffset: number = 0;
  private forumDragStartOffset: number = 0;
  private forumDragFingerY: number = 0;
  private forumDragDirection: number = 0;
  private forumReleaseSpeed: number = 0;
  private forumHeaderSnapApplied: boolean = false;
  @State forumHeaderArt: image.PixelMap | null = null;
  @State forumArtColor: string = '';
  private forumArtUrl: string = '';
  private forumArtEpoch: number = 0;
  // ===== 「沉浸式阅读补全」（2026-09-29，设置 → 个性化）=====
  /** 设置项真源：AppStorage `immersiveReadExtra`（独立开关，默认关）。本页为 @Entry 独立页，无宿主底栏，纯本地态 */
  @StorageLink('immersiveReadExtra') @Watch('onListImmersiveExtraChanged') immersiveReadExtra: boolean = false;
  /** 沉浸态：true = 顶栏（返回/搜索框/搜索/更多）+ 底部组合（排序栏+加号）已藏起。只存页面局部 @State */
  @State immersiveHidden: boolean = false;
  /** 滚动判定器（规则与 ThreadDetail 逐项同源） */
  private listImmersiveSensor: ImmersiveReadSensor = new ImmersiveReadSensor(false);
  /** WaterFlow 数据源（§4.8 T-G）：置顶卡 + 普通帖合并列表，@Watch('onThreadsChanged') 自动同步 */
  @State listDataSource: ThreadListDataSource = new ThreadListDataSource();
  /**
   * WaterFlow 分段配置（§4.8 T-G 修正）：让**吧头成为跨列的首个格子**、随内容一起滚动
   * （替代「吧头固定于滚动容器外」的旧结构）。section 0 = 吧头（全宽），section 1 = 主体（多列）。
   */
  @State sections: WaterFlowSections = new WaterFlowSections();
  /** syncSections 去重键（「主体项数_主体列数」）：避免切排序时同一帧重复 splice 触发 WaterFlow 重排 */
  private lastSectionKey: string = '';
  @State isDark: boolean = isDarkMode();
  @State @Watch('onForumInfoChanged') forumInfo: ForumHeaderInfo | null = null;
  /** 本次进吧是否已把真实吧头像补记进「最近进入」足迹（aboutToAppear 先记空头像，吧头就绪后补齐一次） */
  private visitAvatarSaved: boolean = false;
  @State failedAvatar: boolean = false;
  @State signDays: number = 0;
  @State forumSignedToday: boolean = false;
  @State forumSignKnown: boolean = false;
  private forumSignDate: string = '';
  private forumSignInFlight: boolean = false;
  private forumSignLookupInFlight: boolean = false;
  /**
   * 吧主页右上角「更多」操作面板显隐（系统 CustomDialog + API 26 沉浸光感）。
   * 宿主已由「页面 body 内自绘 Stack 浮层」换成系统 CustomDialog —— 官方 A 档「弹窗类」
   * 只覆盖系统 Dialog / 弹窗类接口，自绘浮层挂 systemMaterial 必然 out of scope。
   * 保留单一布尔状态，真正 open/close 由 @Watch 驱动，既有 `this.showMoreSheet = x` 调用点零改动。
   */
  @State @Watch('onShowMoreChanged') showMoreSheet: boolean = false;
  /** 弹窗展示快照：打开那一刻是否已关注（可空对象 forumInfo 不能直接 @Link 进 @CustomDialog） */
  @State moreSheetLiked: boolean = false;
  /**
   * 跳转官方吧主页确认弹窗显隐（系统 CustomDialog + API 26 沉浸光感）。
   * 与 ThreadDetail 同机制：保留单一布尔状态，真正 open/close 由 @Watch 驱动。
   */
  @State @Watch('onShowJumpChanged') showJumpDialog: boolean = false;
  /** 弹窗内的目标链接预览快照（打开前由宿主算好写入，弹窗内取不到宿主方法） */
  @State jumpUrlPreview: string = '';
  // 吧主页关注/取消关注进行中，防止重复点击
  @State forumFollowBusy: boolean = false;
  @State refreshing: boolean = false;
  // 列表滚动控制器：刷新成功后回到顶部，立即看到最新内容
  private listScroller: Scroller = new Scroller();
  // 本吧搜索：服务端搜索优先（/c/s/searchpost，TiebaLite 同款端点），失败降级为本地扫描吧内分页
  @State searchMode: boolean = false;
  @State searchKeyword: string = '';
  // 结果池：服务端模式 = 服务端命中列表；本地模式 = 扫过的吧内帖子池（再按标题/摘要过滤）
  @State searchPool: ThreadItem[] = [];
  // searchFetching = 正在取数（结果区显示"正在搜索"）；searchExhausted = 已到末尾
  @State searchFetching: boolean = false;
  @State searchExhausted: boolean = false;
  // —— 服务端搜索态（searchServerMode=false 表示已降级为本地扫描，本会话不再重试）——
  private searchServerMode: boolean = true;
  private searchServerPage: number = 0;
  private searchServerHasMore: boolean = true;
  // —— 本地扫描态：池已扫到的吧内页码 / 连续无新增批次数 / 是否还有更多分页 / 已扫页数 ——
  private searchPage: number = 0;
  private searchStalled: number = 0;
  private searchHasMore: boolean = true;
  private searchScannedPages: number = 0;
  // 搜索结果缓存（键 = 关键词 + 池版本）：避免大池在滚动渲染中被反复全量过滤
  private searchPoolVersion: number = 0;
  private searchCacheKey: string = '';
  private searchCacheResult: ThreadItem[] = [];
  // 搜索会话代际：换关键词/退出搜索即自增，使在途结果作废；searchTimer = 输入防抖定时器
  private searchToken: number = 0;
  private searchTimer: number = -1;
  // 自动续载定时器 + 最近滚动偏移：结果不满一屏时无法滚动，必须主动补下一批（否则"加载不出来"）
  private searchAutoTimer: number = -1;
  private lastScrollY: number = 0;
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('floatingPageBars') floatingPageBars: boolean = true;
  /** 页面可见时自增，强制组件重建使字号实时生效 */
  @State fontSizeTick: number = 0;
  // 「列数调整」档位广播（2026-09-18，个性化 → 列数调整）：@Watch 回写本地档位 → 列数函数按新档返回并强制回到列表顶部
  // （离屏期间 @StorageLink 同步不重绘，故用 tick + 本地 @State 兜底，同 fontTick 范式）
  @StorageLink('columnModeTick') @Watch('onColumnModeTick') columnModeTick: number = 0;
  @State columnMode: number = 0;
  /** API26+ 沉浸光感能力：true 时顶栏走官方 title 槽位、FAB 走「空 tabBar 壳」槽位，
   *  否则回退页面主体自绘玻璃（与 ThreadDetail 同判据） */
  @State materialSupported: boolean = false;
  /** 根容器实宽（vp）：底部排序栏槽位壳的 `barWidth` 只接受数值（Dimension 不收 'calc(100% - 48vp)'，
   *  同 Search.ets / 本页 dialogCardWidth 的换算口径），由 ThreadListContent 根 Stack 的 onAreaChange 维护 */
  @State currentWidth: number = 0;
  // ===== 平板适配（docs/TiebaPura平板适配.md §4.8）=====
  /** 大屏形态设备（平板 / 2in1 / 折叠屏）：静态判定一次。折叠屏 deviceType 为 'phone'，必须单独用 isFoldable 识别 */
  private readonly isWideFormDevice: boolean = detectWideFormDevice();
  /** 窗口宽 / 高（vp）：aboutToAppear 同步取首帧初值，onAreaChange 实时兜底 */
  @State pageWidth: number = 0;
  @State pageHeight: number = 0;
  /** 横竖屏判据（pageWidth > pageHeight）：**不能用** viewportW / viewportH 顶替，
   *  那是 Scroll 视口尺寸（横屏时已被顶部 90 占位与底部让位吃掉），与窗口高不等 */
  @State isLandscape: boolean = false;

  // ===== 派生值缓存（2026-09-19）：零风险自失效 —— 键一律取「引用 + 影响结果的状态值」=====
  // 前提（已逐行核）：this.threads 全程整体赋值（concat / map / 字面量 / 外部数组），**无原地 mutate**，
  // 故「引用相等 ⇒ 逐项相等」，引用比较即可判失效，无需人工维护失效点。
  // 缓存字段必须保持普通 private（写成 @State 会在渲染期写状态 → 触发重建 → 死循环）。
  /** threadColumns() 结果缓存：本函数每次 build 被调 5~10 次，而内部整条设备判定链
   *  （isWideBarFullscreen → isWideBarDevice / isLargeScreenForm → isWideBarDevice + isLargeFoldDevice
   *  / isLargeFoldDevice / isWideBarDevice）每次都要调 display.isFoldable() / getFoldStatus() /
   *  getDefaultDisplaySync()，结果却只由 pageWidth / pageHeight / columnMode 决定
   *  （isLandscape 派生自前两者，isWideFormDevice 是 readonly 常量）。
   *  折叠屏展开↔折叠必然改变窗口尺寸 ⇒ 键必变 ⇒ 不会漏翻档。 */
  private colCacheKey: string = '';
  private colCacheValue: number = 0;
  /** 置顶 / 普通拆分缓存：键 = threads 引用 + 排序档（threads 引用一变即整表失效） */
  private pinnedCacheSrc: ThreadItem[] | null = null;
  private pinnedCacheSort: number = -1;
  private pinnedCacheValue: ThreadItem[] = [];
  private normalCacheSrc: ThreadItem[] | null = null;
  private normalCacheSort: number = -1;
  private normalCacheValue: ThreadItem[] = [];
  /** 下一次 push 的目标是否为精选分类页：是则本次退场改静止，避免默认横滑与分类页上滑叠出双动画 */
  private pushingToGoodPage: boolean = false;

  onPageShow(): void {
    // 从精选分类页等二级页返回本页：复位 push 目标标记（本页 onPageShow 只在回栈可见时触发）
    this.pushingToGoodPage = false;
    this.fontSizeTick++;
    if (this.forumName.length > 0) {
      if (this.forumSignDate !== ForumSignStore.todayStamp()) {
        this.restoreSignState();
      } else {
        this.refreshFollowedForumSignStatus();
      }
    }
  }

  /** 退页清理尾部提示延时器：避免定时回调落到已销毁组件（@State 写入告警 / 空引用） */
  aboutToDisappear(): void {
    this.forumArtEpoch++;
    this.releaseForumHeaderArt();
    this.clearLoadingHintTimer();
    // 左右滑切排序的解锁延时器一并清理，避免回调落到已销毁组件
    if (this.swipeLockTimer !== -1) {
      clearTimeout(this.swipeLockTimer);
      this.swipeLockTimer = -1;
    }
    // §AUDIT（2026-09-29 定时器审计）：以下句柄此前均未入清理——
    // pulseTimer/sortSettleTimer 退页后写 @State（含 PixelMap 快照延迟释放），
    // searchTimer/searchAutoTimer 退页后仍会发搜索网络请求，goodPress/listSwipe/listPrefetch
    // 退页后仍会触发预取。
    if (this.pulseTimer !== -1) {
      clearTimeout(this.pulseTimer);
      this.pulseTimer = -1;
    }
    if (this.sortSettleTimer !== -1) {
      clearTimeout(this.sortSettleTimer);
      this.sortSettleTimer = -1;
    }
    if (this.goodPressTimer !== -1) {
      clearTimeout(this.goodPressTimer);
      this.goodPressTimer = -1;
    }
    if (this.listSwipeTimer !== -1) {
      clearTimeout(this.listSwipeTimer);
      this.listSwipeTimer = -1;
    }
    if (this.listPrefetchTimer !== -1) {
      clearTimeout(this.listPrefetchTimer);
      this.listPrefetchTimer = -1;
    }
    this.cancelSearchTimers();
  }

  /**
   * 系统返回手势拦截（同 Index BUG-01 方案）：本吧搜索是页内状态（searchMode，不在路由栈里），
   * 搜索态下系统返回应先退出搜索、回到吧主页帖子列表，而不是把整个吧主页弹出（此前会直接退到进吧页）。
   */
  onBackPress(): boolean {
    if (this.searchMode) {
      this.exitSearch();
      return true;
    }
    return false;
  }
  // 骨架屏→内容交叉淡入淡出（同帖详情方案A）：内容初始透明淡入，骨架屏淡出后由 loadState 切换移除
  @State contentOpacity: number = 0.0;
  @State skeletonOpacity: number = 1.0;
  // 排序切换过场：新页位移 / 旧页快照位移（百分比，相对各自宽度 = 屏宽），与首页 switchTab 同款
  @State inOffset: number = 0;
  @State outOffset: number = 0;
  // 旧页快照（点击那一刻同步截下的**列表区**内容，吧头已被 region 裁掉）：切换期间由一层 Image 承载滑出，收口后释放
  @State exitSnapshot: image.PixelMap | null = null;
  // 旧页快照的顶部裁剪量（vp，点击那一刻算好）：= 吧头块底边在 Scroll 视口里的 y，≥ 0；
  // 0 = 整屏都是列表内容（吧头已滚出屏 / 吧头高未测到）；> 0 时旧页层下移该距离、高度相应收窄，落在列表区上
  @State exitClipTop: number = 0;
  // 本次切换方向（±1；0 = 非排序切换）：位移方向，同时是"是否走排序切换动画"的判据
  private enterDir: number = 0;
  // 动画窗口的结束时刻（ms 时间戳）：窗口内静默刷新只回写缓存不上屏，避免"滑到一半内容变了"
  private sortAnimUntil: number = 0;
  // 过场收口定时器：动画结束后卸载旧页快照并复位位移（快速连切时先清掉上一个）
  private sortSettleTimer: number = -1;
  // tab 按压回弹：点击瞬间缩一下再弹回，增强切换按键手感
  @State pressedTab: number = -1;
  private pulseTimer: number = -1;
  // 左右滑切排序的滑动锁：横向 PanGesture 起手即上锁、抬指延时解锁；
  // 锁住期间 openThread 短路 —— 滑动手势期间抬指仍可能给卡片派发 click（GoodCategoryPage 真机结论）
  private swipeLock: boolean = false;
  private swipeLockTimer: number = -1;
  // 上一次抬指判定时刻：内层 Stack 与 WaterFlow/Scroll 多挂点会同触发同一手势，用它去重
  private lastSwipeHandledMs: number = 0;
  // 延迟初始化：aboutToAppear生命周期阶段UIContext就绪后赋值，避免类字段初始化期获取null
  private context?: common.UIAbilityContext;

  /**
   * 安全获取 UIAbilityContext：优先使用已缓存this.context；兜底现场获取
   */
  private getUIAbilityContext(): common.UIAbilityContext {
    if (this.context) {
      return this.context;
    }
    const liveCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (liveCtx) {
      this.context = liveCtx;
    }
    return liveCtx;
  }

  /**
   * 吧主页帖子分享：Share Kit 系统分享面板（参考CSDN宿主应用发起分享）；主路径失败→剪贴板兜底复制链接
   * 排障：最外层try/catch捕获所有异常→Toast显式反馈，避免用户感觉"点了没反应"
   */
  private shareThread(data: ThreadSharePayload): void {
    try {
      if (!data || data.tid.length === 0) {
        this.getUIContext().getPromptAction().showToast({ message: '帖子信息缺失，无法分享' });
        return;
      }
      const threadUrl: string = `https://tieba.baidu.com/p/${data.tid}`;
      const titleLine: string =
        data.forumName.length > 0 ? `[${data.forumName}] ${data.title}` : data.title;
      const rawAbstract: string = data.abstract ?? '';
      const descriptionText: string =
        rawAbstract.length > 0
          ? (rawAbstract.length > 140 ? `${rawAbstract.substring(0, 140)}…` : rawAbstract)
          : '';
      const fullText: string =
        descriptionText.length > 0
          ? `${titleLine}\n${descriptionText}\n${threadUrl}`
          : `${titleLine}\n${threadUrl}`;
      const abilityCtx: common.UIAbilityContext = this.getUIAbilityContext();
      if (!abilityCtx) {
        this.getUIContext().getPromptAction().showToast({ message: '系统分享不可用，正在复制链接' });
        this.copyShareToClipboard(fullText, titleLine, threadUrl);
        return;
      }

      try {
        // ★ 官方Codelabs L426-438 纯链接分享：utd.UniformDataType.HYPERLINK + content字段（图片才用uri+fileUri）
        const sharedData: systemShare.SharedData = new systemShare.SharedData({
          utd: utd.UniformDataType.HYPERLINK,
          content: threadUrl,
          title: titleLine,
          description: descriptionText
        });
        const controller: systemShare.ShareController = new systemShare.ShareController(sharedData);
        // ★ 官方Codelabs关键修正：controller.show()返回Promise，必须单独.catch()才能捕获异步错误
        controller.show(abilityCtx, {
          previewMode: systemShare.SharePreviewMode.DETAIL,
          selectionMode: systemShare.SelectionMode.SINGLE
        }).then(() => {
          this.getUIContext().getPromptAction().showToast({ message: '系统分享面板已弹出' });
        }).catch((showErr: BusinessError) => {
          const code = showErr?.code ?? 'unknown';
          const msg = showErr?.message ?? String(showErr);
          this.getUIContext().getPromptAction().showToast({
            message: `分享面板失败[${code}]：${msg}`
          });
          this.copyShareToClipboard(fullText, titleLine, threadUrl);
        });
        return;
      } catch (_) {
        this.getUIContext().getPromptAction().showToast({ message: '系统分享不可用，正在复制链接' });
        this.copyShareToClipboard(fullText, titleLine, threadUrl);
      }
    } catch (outerErr) {
      const errMsg: string = outerErr instanceof Error ? outerErr.message : String(outerErr);
      this.getUIContext().getPromptAction().showToast({ message: `分享异常：${errMsg}` });
    }
  }

  /**
   * 兜底写入系统剪贴板：分享面板不可用时用户仍可粘贴发送
   */
  private copyShareToClipboard(fullText: string, title: string, url: string): void {
    try {
      const sysPasteboard = pasteboard.getSystemPasteboard();
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, fullText);
      sysPasteboard.setData(pasteData, (err: BusinessError | undefined) => {
        if (err) {
          this.getUIContext().getPromptAction().showToast({
            message: `复制失败：${err.message || String(err)}`
          });
        } else {
          this.getUIContext().getPromptAction().showToast({
            message: `已复制「${title}」链接，粘贴即可分享`
          });
        }
      });
    } catch (clipboardErr) {
      const errMsg: string = clipboardErr instanceof Error ? clipboardErr.message : String(clipboardErr);
      this.getUIContext().getPromptAction().showToast({
        message: `剪贴板不可用：${errMsg}；帖子链接：${url}`
      });
    }
  }

  /**
   * 吧主页右上角「分享吧」：通过系统分享面板分享吧链接。
   * 主路径失败 → 剪贴板兜底复制链接。
   */
  private shareForum(): void {
    try {
      const forumUrl: string = `https://tieba.baidu.com/f?kw=${encodeURIComponent(this.forumName)}`;
      const titleLine: string = `「${this.forumInfo?.forumName ?? this.forumName}」吧`;
      const descriptionText: string = (this.forumInfo?.slogan ?? '').length > 0
        ? (this.forumInfo!.slogan.length > 140 ? `${this.forumInfo!.slogan.substring(0, 140)}…` : this.forumInfo!.slogan)
        : '';
      const fullText: string = descriptionText.length > 0
        ? `${titleLine}\n${descriptionText}\n${forumUrl}`
        : `${titleLine}\n${forumUrl}`;
      const abilityCtx: common.UIAbilityContext = this.getUIAbilityContext();
      if (!abilityCtx) {
        this.getUIContext().getPromptAction().showToast({ message: '系统分享不可用，正在复制链接' });
        this.copyShareToClipboard(fullText, titleLine, forumUrl);
        return;
      }
      try {
        const sharedData: systemShare.SharedData = new systemShare.SharedData({
          utd: utd.UniformDataType.HYPERLINK,
          content: forumUrl,
          title: titleLine,
          description: descriptionText
        });
        const controller: systemShare.ShareController = new systemShare.ShareController(sharedData);
        controller.show(abilityCtx, {
          previewMode: systemShare.SharePreviewMode.DETAIL,
          selectionMode: systemShare.SelectionMode.SINGLE
        }).then(() => {
          this.getUIContext().getPromptAction().showToast({ message: '系统分享面板已弹出' });
        }).catch((showErr: BusinessError) => {
          const code = showErr?.code ?? 'unknown';
          const msg = showErr?.message ?? String(showErr);
          this.getUIContext().getPromptAction().showToast({
            message: `分享面板失败[${code}]：${msg}`
          });
          this.copyShareToClipboard(fullText, titleLine, forumUrl);
        });
      } catch (_) {
        this.getUIContext().getPromptAction().showToast({ message: '系统分享不可用，正在复制链接' });
        this.copyShareToClipboard(fullText, titleLine, forumUrl);
      }
    } catch (outerErr) {
      const errMsg: string = outerErr instanceof Error ? outerErr.message : String(outerErr);
      this.getUIContext().getPromptAction().showToast({ message: `分享异常：${errMsg}` });
    }
  }

  /** 克隆吧头信息并覆写关注态（ArkTS 禁用对象展开，只能逐字段构造） */
  private withFollowState(info: ForumHeaderInfo, isLike: boolean): ForumHeaderInfo {
    return {
      forumId: info.forumId,
      forumName: info.forumName,
      avatar: info.avatar,
      bannerUrl: info.bannerUrl,
      headerImage: info.headerImage,
      headerImageColor: info.headerImageColor,
      headerColor: info.headerColor,
      darkHeaderColor: info.darkHeaderColor,
      slogan: info.slogan,
      memberCount: info.memberCount,
      threadCount: info.threadCount,
      postCount: info.postCount,
      userLevel: info.userLevel,
      levelName: info.levelName,
      curScore: info.curScore,
      levelupScore: info.levelupScore,
      isLike: isLike,
      hasFrsStar: info.hasFrsStar
    };
  }

  /**
   * 吧主页「关注 / 取消关注」：根据当前 forumInfo.isLike 反向操作。
   * 乐观更新吧头状态，失败时回滚并提示。
   * 不可变更新（整体替换）而非就地改属性：保证签到钮「未关注 / 未签到」文案
   * 与「吧操作」面板的「已关注」标签都能可靠刷新。
   */
  private async handleForumFollow(): Promise<void> {
    if (this.forumFollowBusy) {
      return;
    }
    if (!this.forumInfo) {
      this.getUIContext().getPromptAction().showToast({ message: '吧信息尚未加载，请稍后再试' });
      return;
    }
    const fid: string = this.forumInfo.forumId;
    if (fid.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '贴吧 ID 缺失，无法操作' });
      return;
    }
    this.forumFollowBusy = true;
    const previous: ForumHeaderInfo = this.forumInfo;
    const wasLiked: boolean = previous.isLike;
    this.forumInfo = this.withFollowState(previous, !wasLiked);
    try {
      await TiebaService.getInstance().toggleFollow(this.forumName, !wasLiked, fid);
      // 关注/取关成功：失效关注列表缓存（30min TTL 旧快照会兜底旧数据）+ 广播进吧页。
      // 携带变更内容（吧名/关注态/头像/fid）：服务端关注列表接口有延迟，进吧页先乐观呈现再对账
      CacheManager.getInstance().delete(CACHE_KEY.FOLLOW_LIST).catch(() => {});
      AppStorage.setOrCreate<string>('forumFollowsChangeName', this.forumName);
      AppStorage.setOrCreate<string>('forumFollowsChangeFollowed', wasLiked ? '0' : '1');
      AppStorage.setOrCreate<string>('forumFollowsChangeAvatar', this.forumInfo.avatar);
      AppStorage.setOrCreate<string>('forumFollowsChangeFid', fid);
      AppStorage.setOrCreate<number>('forumFollowsChanged', (AppStorage.get<number>('forumFollowsChanged') ?? 0) + 1);
      this.getUIContext().getPromptAction().showToast({ message: wasLiked ? '已取消关注' : '已关注' });
    } catch (e) {
      // 失败回滚状态
      this.forumInfo = previous;
      this.getUIContext().getPromptAction().showToast({
        message: (e instanceof Error ? e.message : String(e)) || '操作失败，请稍后重试'
      });
    } finally {
      this.forumFollowBusy = false;
    }
  }

  /**
   * 排序切换入口（热门 / 最新 / 精选）——首页 `switchTab` 同款的「两页对向平移」，见文件头 SORT_ANIM_* 注释。
   *
   * ① 收口上一次未播完的过场（快速连切，避免两条动画互相覆盖）→ ② **同步截下当前列表区**作为旧页
   * （此刻旧内容还完整在场、滚动位置正确，早于此或晚于此都截不到；吧头由 region 裁掉，见
   * `captureExitSnapshot`）→ ③ 记方向、换排序与分页状态
   * → ④ 数据侧加载（loadThreads）。数据就位后由 `applySortDisplay` 在同一帧内完成
   * 「替换 + 回顶 + 摆起点 + 双页对向起滑」，中途不插等待帧、没有第二段动画 ——
   * 页内快照是同步命中，所以最常走的路径就是"点下去那一帧两页就开始对向平移"。
   *
   * 注意：此处**不清空** `this.threads` —— 数据到达前保持旧列表可见，避免闪空；
   * 若本次未命中缓存，则由 `applySortDisplay` 落骨架屏等网络返回（网络回来才走过场）。
   */
  private selectSort(sort: number): void {
    // P0-2 归因打点：切排序 = 窗口复位 + 整表换血 + 过场动画三件事同帧
    PerfTrace.mark('sortSwitch');
    // 窗口化挂载：切排序/重复点击回顶前先复位窗口（数据换血另有长度缩短兜底）
    this.slotReset();
    if (this.selectedSort === sort) {
      // 重复点击当前排序 = 刷新该排序（先回顶、再拉第 1 页，见 refreshByRetap）。
      // 与切排序不同：不动选中态、不播过场动画，只做「回顶 + 刷新」。
      this.refreshByRetap(sort);
      return;
    }
    // ① 收口上一次过场（同时释放上一次的旧页快照）
    this.clearSortSettle();
    // ② 旧页快照：同步截取当前屏幕（必须在数据被替换之前）
    this.captureExitSnapshot();
    // ③ 方向：目标 tab 在右侧（索引增大）→ 新页自右侧进入、旧页向左滑出，反向则相反
    this.enterDir = (sort + 1) % 3 > (this.selectedSort + 1) % 3 ? 1 : -1;
    this.selectedSort = sort;
    this.page = 1;
    this.hasMore = true;
    this.stalledPages = 0;
    // ④ 数据侧：页内快照 / 本地缓存 / 网络在 loadThreads 内依次尝试（命中快照时同步上屏，见其注释）
    this.loadThreads();
  }

  /**
   * 重复点击当前排序（当前已是「热门」再点热门，最新 / 精选同理）：**回到列表顶部 + 重新拉取第 1 页**。
   * 本页刷新入口自 2026-09-12 起**只此一处**（右下角刷新钮已按用户要求移除），链路即 `handleRefresh()`：
   * 网络刷新第 1 页、8s 超时兜底、「刷新成功 / 失败」toast、后台昵称校准与缓存回写；
   * 多出的一步是**先立即回顶**（不等网络返回），让等待期间用户已经看到顶部内容
   * （handleRefresh 成功后还会再回顶一次，幂等）。
   * busy（已有刷新在跑）时只回顶、不重复发请求 —— 与 handleRefresh 的 busy 短路口径一致。
   * 数据侧的附带收益：新列表经 `threads` 的 @Watch（onThreadsChanged）自动回写 `sortSession` 快照，
   * 切走再切回该排序拿到的已是刷新后的数据。
   */
  private refreshByRetap(sort: number): void {
    console.info(`[SORT] retap cur=${sort} -> scroll top + refresh`);
    // ① 立即回顶：动画与刷新成功后的回顶保持一致（不阻塞、不等待网络）
    this.listScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: 300, curve: Curve.EaseOut } });
    // ② 复用既有刷新链路（内部自带 busy 短路、超时兜底与 toast 反馈）
    this.handleRefresh();
  }

  /** tab 点击按压脉冲：缩小一下再弹回，提升切换按键手感 */
  private pulseTab(sort: number): void {
    if (this.pulseTimer !== -1) {
      clearTimeout(this.pulseTimer);
    }
    this.pressedTab = sort;
    this.pulseTimer = setTimeout(() => {
      this.pressedTab = -1;
      this.pulseTimer = -1;
    }, 90);
  }

  // ===== 左右滑切排序（2026-09-22）：HomeTab 推荐流 / GoodCategoryPage 同款机制 =====
  // 外层普通容器 parallelGesture 挂横向 PanGesture（挂列表 Scroll/WaterFlow 上会被内部滚动消费），
  // 与竖向滚动并行识别；起手即锁卡点按，抬指按位移方向切到相邻排序（走 selectSort 既有的
  // 「旧页快照 + 两页对向平移」过场，方向 enterDir 自动随目标索引推导）。

  private lockSwipe(): void {
    this.swipeLock = true;
    if (this.swipeLockTimer !== -1) {
      clearTimeout(this.swipeLockTimer);
      this.swipeLockTimer = -1;
    }
  }

  private unlockSwipeDelayed(): void {
    if (this.swipeLockTimer !== -1) {
      clearTimeout(this.swipeLockTimer);
    }
    this.swipeLockTimer = setTimeout(() => {
      this.swipeLockTimer = -1;
      this.swipeLock = false;
    }, THREAD_LIST_SWIPE_UNLOCK_DELAY);
  }

  /**
   * 抬指判定：左滑（dx 为负）切到右侧相邻排序、右滑切回左侧；
   * 位移不足阈值或已在边界（最新→热门再右滑 / 精选再左滑）不动。
   * 搜索态不参与（搜索结果无排序档，且须让位给横滑选择文本等交互）。
   * 同一次手势会从内层 Stack（parallelGesture）与 WaterFlow/Scroll 节点（.gesture）多个挂点
   * 各触发一次回调 —— 用 350ms 时间戳去重，保证一次滑动只切一档。
   */
  private onSortSwipeEnd(event: GestureEvent): void {
    if (this.searchMode) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastSwipeHandledMs < 350) {
      return;
    }
    this.lastSwipeHandledMs = now;
    const dx: number = event.offsetX;
    const index: number = (this.selectedSort + 1) % 3;
    if (dx < -THREAD_LIST_SWIPE_SWITCH_THRESHOLD && index < 2) {
      this.selectSort(index);
    } else if (dx > THREAD_LIST_SWIPE_SWITCH_THRESHOLD && index > 0) {
      this.selectSort((index + 1) % 3);
    }
  }

  aboutToAppear(): void {
    // P0-2 归因打点：吧主页是本轮报告里覆盖设备数最多的一页，进入即登记页面上下文
    PerfTrace.setPage('ThreadList');
    this.initLatestSortModeThenLoad();
  }

  /**
   * 「最新」档子排序恢复 + 首次加载（原 aboutToAppear 主体）。
   * 子档持久化读盘是异步的，必须 await 后再 loadThreads：缓存 key（forumCacheKey）与请求参数
   * 都以 effectiveSort() 为真源，先恢复再拉取才能命中正确的子档缓存。
   */
  private async initLatestSortModeThenLoad(): Promise<void> {
    // 生命周期阶段UIContext已就绪，安全初始化context缓存
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // 首帧形态初值（§4.6 H-A / §4.8 T-B 同源）：onAreaChange 只在尺寸变化后触发，冷启动平板横屏若不预置
    // 会出现「先 1 列再跳 4 列」的首帧跳变。取不到就保持 0，由 onAreaChange 兜底。
    try {
      const d = display.getDefaultDisplaySync();
      const w: number = this.getUIContext().px2vp(d.width);
      const h: number = this.getUIContext().px2vp(d.height);
      if (w > 0 && h > 0) {
        this.pageWidth = w;
        this.pageHeight = h;
        this.isLandscape = w > h;
      }
    } catch (e) {
      // 忽略：窗口未 attach 时取宽会失败，onAreaChange 会兜底
    }
    // 「列数调整」档位初值（2026-09-18）：冷启动首帧即按已选档渲染
    // （UsageHabitsManager.init 的 columnModeTick 可能早于本页构造，@Watch 不会补触发，故此处直读）
    this.columnMode = readColumnMode();
    // 列数标记下发：**无条件写**（单列也写 1），避免跨页残留（§6.1 D1 / D6）
    this.syncCardColumns();
    // WaterFlow 分段初值（§4.8 T-G）：吧头跨列格子 + 主体多列格子
    this.syncSections();
    MaterialManager.init();
    this.materialSupported = MaterialManager.isSupported() && MaterialManager.getApiLevel() >= 26;
    const params = this.getUIContext().getRouter().getParams() as Record<string, string>;
    if (params) {
      if (params.kw) {
        this.forumName = `${params.kw}`;
      } else if (params.forumName) {
        this.forumName = `${params.forumName}`;
      }
      if (params.fid) {
        this.forumId = `${params.fid}`;
      }
    }
    this.isDark = isDarkMode();
    // 「最近进入」足迹：进入吧主页即记录（此前仅打开帖子才写浏览历史 → 最近进入长期缺失）。异步不阻塞首屏。
    // 吧头信息就绪前先记空头像（HistoryStore 对空头像保留旧值），就绪后由 onForumInfoChanged 补记真实头像。
    this.visitAvatarSaved = false;
    if (this.forumName.length > 0) {
      HistoryStore.getInstance().recordForumVisit(this.forumName, this.forumId, '').catch(() => {
      });
    }
    if (this.forumName.length === 0) {
      this.loadState = LoadState.Error;
      this.errorMsg = '缺少贴吧名称，无法进入吧主页';
      return;
    }
    this.restoreSignState();
    // 「吧主页默认进入界面」档位初值（使用习惯页设置）：0 = 热门（默认，老用户零回归）/ 1 = 最新。
    // 必须在 loadThreads 之前写：缓存 key（forumCacheKey）与请求参数都以 selectedSort 为真源。
    const savedSort: number = AppStorage.get<number>('forumDefaultSort') ?? 0;
    this.selectedSort = (savedSort >= 0 && savedSort <= 2) ? savedSort : 0;
    // 「最新」档子排序恢复（全局档）：0 = 按回复时间 / 1 = 按发帖时间（缺省 1 零回归）。
    // 同样必须在 loadThreads 之前写（失败静默走缺省）。
    try {
      const raw = await CacheManager.getInstance().get(CACHE_KEY.LATEST_SORT_MODE);
      if (raw === '0' || raw === '1') {
        this.latestSortMode = parseInt(raw, 10);
      }
    } catch (_) {
      // 读盘失败走缺省 1（现状），不阻塞首屏
    }
    this.loadThreads();
  }

  private openThread(tid: string): void {
    // 左右滑切排序期间锁点按：滑动抬指时手势仲裁仍可能给卡片派发 click，这里直接短路防误开帖
    if (this.swipeLock) {
      return;
    }
    if (tid.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '帖子信息暂不可用' });
      return;
    }
    // 点击即预取：利用跳转动画窗口后台取详情，详情页打开即命中缓存秒开
    TiebaService.getInstance().prefetchThreadDetail(tid, this.forumId);
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ThreadDetail',
      params: { tid: tid, forum: this.forumName, fid: this.forumId }
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '帖子打开失败，请稍后重试' });
    });
  }

  /** 头像点击：跳转作者用户主页 */
  private openUserProfile(authorId: string, author: string): void {
    const id: string = `${authorId ?? ''}`.trim();
    if (id.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '该用户信息暂不可用' });
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UserProfile',
      params: { userId: id, userName: author }
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '用户主页打开失败，请稍后重试' });
    });
  }

  // ===== 精选二级分类页入口（2026-09-20）：底栏「精选」钮长按，按下即预取 =====

  /** 本次进吧只预取一次精选首屏 */
  private goodPrefetchDone: boolean = false;
  private goodPressTimer: number = -1;

  /**
   * 精选钮触摸：Down 起 60ms 计时（长按意图在 350ms 阈值前就起跑预取请求），
   * Up / Cancel 撤销 —— 快速点按（切排序自会拉取）不白发预取。
   */
  private onGoodButtonTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      if (this.goodPressTimer !== -1) {
        clearTimeout(this.goodPressTimer);
      }
      this.goodPressTimer = setTimeout(() => {
        this.goodPressTimer = -1;
        this.startGoodPrefetch();
      }, 60);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.goodPressTimer !== -1) {
        clearTimeout(this.goodPressTimer);
        this.goodPressTimer = -1;
      }
    }
  }

  /** 预取精选首屏（GoodCategoryPage 首屏合流消费）；5 分钟内的新鲜磁盘缓存已在则跳过省流量 */
  private startGoodPrefetch(): void {
    if (this.goodPrefetchDone) {
      return;
    }
    this.goodPrefetchDone = true;
    CacheManager.getInstance().getWithTtlAllowStale<ForumListCache>(this.forumCacheKey('2'))
      .then((cached) => {
        if (cached && !cached.expired && cached.data.threads.length > 0) {
          return;
        }
        TiebaService.getInstance().prefetchGoodFirstPage(this.forumName);
      })
      .catch(() => {
        TiebaService.getInstance().prefetchGoodFirstPage(this.forumName);
      });
  }

  /** 长按「精选」：进入精选二级分类页（页面自下而上转场，零提示静默进入） */
  private openGoodCategories(): void {
    Haptic.light();
    // 本次 push 的退场改静止（见 pageTransition）：分类页自带自下而上入场，
    // 若本页仍走系统默认横滑退场，平板宽屏上会叠出「一个上滑 + 一个左滑」双动画
    this.pushingToGoodPage = true;
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/GoodCategoryPage',
      params: { kw: this.forumName, fid: this.forumId }
    }).catch(() => {});
  }

  /**
   * pop 返回到本页（详情 / 楼中楼 / 搜索 / 精选分类页等）：本页**静态揭出**（1ms 收场）。
   * router 默认底层页横滑入场，会与精选分类页的「自下而上退场」叠出多余的水平动画（真机反馈）；
   * push 进本页（从首页进吧）不受影响仍走系统默认。
   * push 退场：仅当本次 push 目标是精选分类页时改**静止**（1ms）——分类页自带自下而上入场，
   * 本页默认横滑退场会与之叠成双动画（真机反馈，平板宽屏尤为明显）；其余 push（进详情等）保持系统默认。
   */
  pageTransition() {
    PageTransitionEnter({ type: RouteType.Pop, duration: 1 });
    if (this.pushingToGoodPage) {
      PageTransitionExit({ type: RouteType.Push, duration: 1 });
    }
  }

  private openCompose(): void {
    if (!this.forumName.trim()) {
      this.getUIContext().getPromptAction().showToast({ message: '吧信息暂不可用' });
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ComposeThread',
      params: { kw: this.forumName, fid: this.forumInfo?.forumId || this.forumId }
    }).catch(() => { this.openJumpDialog(); });
  }

  /** 本吧搜索：进入搜索态（服务端搜索优先，失败降级本地扫描；退出返回帖子列表） */
  private openSearch(): void {
    // 搜索框在顶栏内，搜索态不参与沉浸：复位显示（2026-09-29）
    this.resetListImmersive();
    this.forumHeaderOffset = 0;
    this.forumPullOffset = 0;
    this.searchMode = true;
    this.searchKeyword = '';
    this.resetSearchSession();
  }

  private exitSearch(): void {
    this.resetListImmersive();
    this.searchMode = false;
    this.searchKeyword = '';
    this.resetSearchSession();
    // 退出即释放搜索池，避免大数组常驻
    this.searchPool = [];
    this.searchPoolVersion++;
  }

  /**
   * 重开搜索会话：作废在途结果（代际自增）、取消定时器、复位双模式进度，
   * 并重试服务端搜索（上次失败可能只是瞬时风控）。
   * 本地模式的初始池取当前列表已有帖子——同排序时列表已覆盖 1..page 页，
   * 扫描直接从下一页起，不重复请求，输入首个字符就能先看到池内已有匹配。
   */
  private resetSearchSession(): void {
    this.searchToken++;
    this.cancelSearchTimers();
    this.searchFetching = false;
    this.searchExhausted = false;
    this.searchServerMode = true;
    this.searchServerPage = 0;
    this.searchServerHasMore = true;
    this.searchPool = this.threads.slice();
    this.searchPoolVersion++;
    this.searchPage = this.selectedSort === SEARCH_SCAN_SORT ? this.page : 0;
    this.searchStalled = 0;
    this.searchHasMore = true;
    this.searchScannedPages = 0;
  }

  /** 取消搜索相关的两个定时器（输入防抖 + 自动续载） */
  private cancelSearchTimers(): void {
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    if (this.searchAutoTimer !== -1) {
      clearTimeout(this.searchAutoTimer);
      this.searchAutoTimer = -1;
    }
  }

  /**
   * 关键词输入（防抖 SEARCH_DEBOUNCE_MS）：重启本关键词的取数。
   * 服务端模式换词必须清空重取（结果与关键词强相关）；
   * 本地模式池跨关键词保留——改词只重算匹配、不重扫，因此越搜越快。
   */
  private onSearchKeywordChange(v: string): void {
    this.searchKeyword = v;
    this.searchToken++;
    this.searchExhausted = false;
    this.searchFetching = false;
    this.cancelSearchTimers();
    if (v.trim().length === 0) {
      return;
    }
    const myToken: number = this.searchToken;
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1;
      if (myToken !== this.searchToken || !this.searchMode) {
        return;
      }
      this.startSearch();
    }, SEARCH_DEBOUNCE_MS);
  }

  /** 开搜：按当前模式取第一批（服务端优先；已降级则本地扫描） */
  private startSearch(): void {
    this.cancelSearchTimers();
    if (this.searchServerMode) {
      this.searchServerPage = 0;
      this.searchServerHasMore = true;
      this.searchPool = [];
      this.searchPoolVersion++;
      this.searchServerFetch(true);
    } else {
      this.searchStalled = 0;
      this.searchScan(SEARCH_BATCH_RESULTS);
    }
  }

  /**
   * 服务端吧内搜索取页（TiebaLite 同款 /c/s/searchpost）：一页 SEARCH_SERVER_PAGE_SIZE 条，
   * 一次请求即整屏命中——这是"结果少 + 下滑加载慢"的根治手段。
   * 首屏失败（风控/未登录/结构变动）→ 本会话降级为本地扫描，保证搜索始终可用。
   */
  private async searchServerFetch(reset: boolean): Promise<void> {
    if (this.searchFetching || !this.searchMode || this.searchKeyword.trim().length === 0) {
      return;
    }
    if (!reset && !this.searchServerHasMore) {
      this.searchExhausted = true;
      return;
    }
    this.searchFetching = true;
    const myToken: number = this.searchToken;
    const nextPage: number = reset ? 1 : this.searchServerPage + 1;
    let fellBack: boolean = false;
    try {
      const result: ForumSearchData = await TiebaService.getInstance()
        .searchPostInForum(this.forumName, this.searchKeyword, nextPage, SEARCH_SERVER_PAGE_SIZE);
      if (myToken !== this.searchToken || !this.searchMode) {
        return;
      }
      this.searchServerPage = nextPage;
      this.searchServerHasMore = result.hasMore;
      const appended: ThreadItem[] = [];
      if (reset) {
        this.searchPool = result.list;
        this.searchPoolVersion++;
        appended.push(...result.list);
      } else {
        appended.push(...this.mergeSearchPage(result.list));
      }
      this.searchExhausted = !this.searchServerHasMore;
      if (appended.length > 0) {
        this.enrichInBackground(appended);
        this.enrichSearchDetails(appended);
      }
    } catch (e) {
      if (myToken !== this.searchToken) {
        return;
      }
      if (reset) {
        // 首屏就失败 → 降级本地扫描（保留关键词，立即起扫）
        console.info(`[FSEARCH] server search failed, fallback to local scan: ${(e as Error).message}`);
        this.searchServerMode = false;
        this.searchServerPage = 0;
        this.searchServerHasMore = true;
        this.searchStalled = 0;
        this.searchScannedPages = 0;
        this.searchHasMore = true;
        this.searchPool = this.threads.slice();
        this.searchPoolVersion++;
        this.searchPage = this.selectedSort === SEARCH_SCAN_SORT ? this.page : 0;
        fellBack = true;
      } else {
        // 翻页失败：保留已有结果，停在当前页，用户继续下滑即重试
        console.warn(`[FSEARCH] server page ${nextPage} failed: ${(e as Error).message}`);
      }
    } finally {
      if (myToken === this.searchToken) {
        this.searchFetching = false;
        if (fellBack) {
          this.searchScan(SEARCH_BATCH_RESULTS);
        } else {
          this.maybeAutoContinueSearch();
        }
      }
    }
  }

  /** 单页扫描：失败/无数据返回 null（由调用方按批计停滞，不打断整批） */
  private async fetchSearchPage(pn: number): Promise<ThreadItem[] | null> {
    try {
      const result = await TiebaService.getInstance().fetchForumThreads(this.forumName, pn, SEARCH_SCAN_SORT, false);
      return result.list;
    } catch (e) {
      return null;
    }
  }

  /**
   * 本地扫描（降级路径）：按 SEARCH_CONCURRENCY 并发抓取后续吧内分页，直到匹配数达到 target、
   * 连续 3 批无新增（触底或持续失败）或达到单批/总量页数上限；结果按轮合并、逐轮上屏。
   * 池固定用「热门」序，与当前排序 Tab 无关，也不写列表缓存（避免与 Tab 列表串源）。
   */
  private async searchScan(target: number): Promise<void> {
    if (this.searchFetching || !this.searchMode || this.searchKeyword.trim().length === 0) {
      return;
    }
    if (!this.searchHasMore || this.searchScannedPages >= SEARCH_SCAN_MAX_PAGES) {
      this.searchExhausted = true;
      return;
    }
    this.searchFetching = true;
    const myToken: number = this.searchToken;
    let scanned: number = 0;
    try {
      while (scanned < SEARCH_BATCH_PAGES && this.searchHasMore
        && this.searchScannedPages + scanned < SEARCH_SCAN_MAX_PAGES
        && this.searchThreads().length < target) {
        if (myToken !== this.searchToken || !this.searchMode) {
          return;
        }
        // 本批页码：池尾之后并发 K 页（并行抓取，避免逐页串行白等）
        const pages: number[] = [];
        for (let i = 0; i < SEARCH_CONCURRENCY && scanned < SEARCH_BATCH_PAGES; i++) {
          pages.push(this.searchPage + i + 1);
          scanned++;
        }
        const lists: (ThreadItem[] | null)[] = await Promise.all(
          pages.map((pn: number): Promise<ThreadItem[] | null> => this.fetchSearchPage(pn)));
        if (myToken !== this.searchToken || !this.searchMode) {
          return;
        }
        const appended: ThreadItem[] = [];
        for (const list of lists) {
          if (list !== null && list.length > 0) {
            appended.push(...this.mergeSearchPage(list));
          }
        }
        this.searchPage += pages.length;
        this.searchScannedPages += pages.length;
        // 连续 3 批无新增即认为本吧已扫到底（触底时接口抛"暂无帖子"，与异常同样表现为无新增）
        this.searchStalled = appended.length > 0 ? 0 : this.searchStalled + 1;
        if (this.searchStalled >= 3) {
          this.searchHasMore = false;
        }
        // 新扫描项的昵称后台校准：按批一次，避免逐页堆叠请求
        if (appended.length > 0) {
          this.enrichInBackground(appended);
        }
      }
    } finally {
      if (myToken === this.searchToken) {
        this.searchFetching = false;
        this.searchExhausted = !this.searchHasMore || this.searchScannedPages >= SEARCH_SCAN_MAX_PAGES;
        this.maybeAutoContinueSearch();
      }
    }
  }

  /** 取下一批（按模式分派）：滚动预加载 / 触底兜底 / 自动续载的统一入口 */
  private searchNextBatch(): void {
    if (!this.searchMode || this.searchExhausted || this.searchFetching) {
      return;
    }
    if (this.searchKeyword.trim().length === 0) {
      return;
    }
    if (this.searchServerMode) {
      this.searchServerFetch(false);
    } else {
      this.searchScan(this.searchThreads().length + SEARCH_BATCH_RESULTS);
    }
  }

  /**
   * 自动续载（修复"下滑加载不出来"）：
   * 结果不满一屏时用户根本无法滚动 → onScroll / onReachEnd 都不会触发 → 永远等不到下一批。
   * 故只要「视口没被填满」或「用户就停在结果底部」，就主动补下一批，不必等用户再滑；
   * 用户上滑离开底部后自然停止，因此不会无谓地持续拉取。
   */
  private maybeAutoContinueSearch(): void {
    if (!this.searchMode || this.searchExhausted || this.searchFetching || this.searchAutoTimer !== -1) {
      return;
    }
    if (this.searchKeyword.trim().length === 0 || this.viewportH <= 0) {
      return;
    }
    if (this.searchServerMode && this.searchPool.length >= SEARCH_SERVER_AUTO_MAX) {
      return;   // 已达自动续载上限，后续仅由用户下滑驱动
    }
    const notFilled: boolean = this.contentH <= this.viewportH + 40;
    const remaining: number = this.contentH - this.viewportH - this.lastScrollY;
    const atBottom: boolean = remaining <= THREAD_PREFETCH_DISTANCE;
    if (!notFilled && !atBottom) {
      return;
    }
    const myToken: number = this.searchToken;
    this.searchAutoTimer = setTimeout(() => {
      this.searchAutoTimer = -1;
      if (myToken !== this.searchToken || !this.searchMode) {
        return;
      }
      this.searchNextBatch();
    }, SEARCH_AUTO_CONTINUE_MS);
  }

  /** 把一页吧内结果去重合并进列表并推进分页状态，返回新增条数（吧主页列表翻页专用） */
  private mergePage(nextPage: number, list: ThreadItem[]): number {
    const existing: Set<string> = new Set<string>();
    for (const item of this.threads) {
      existing.add(item.tid);
    }
    const appended: ThreadItem[] = [];
    for (const item of list) {
      if (!existing.has(item.tid)) {
        existing.add(item.tid);
        appended.push(item);
      }
    }
    this.page = nextPage;
    this.stalledPages = appended.length > 0 ? 0 : this.stalledPages + 1;
    this.hasMore = list.length > 0 && this.stalledPages < 3;
    if (appended.length > 0) {
      this.threads = this.threads.concat(appended);
      this.enrichInBackground(appended);
      this.saveForumCache(this.threads);
    }
    return appended.length;
  }

  /** 服务端搜索结果补数据：按 tid 拉详情补齐 authorId/头像/回复数/点赞数 */
  private enrichSearchDetails(list: ThreadItem[]): void {
    if (!this.searchServerMode || list.length === 0) {
      return;
    }
    const myToken: number = this.searchToken;
    const targets: ThreadItem[] = list.filter((t: ThreadItem): boolean =>
      (t.authorId ?? '').length === 0 || (t.authorAvatar ?? '').length === 0);
    if (targets.length === 0) {
      return;
    }
    let cursor: number = 0;
    const worker = async (): Promise<void> => {
      while (cursor < targets.length) {
        const item: ThreadItem = targets[cursor];
        cursor++;
        if (myToken !== this.searchToken || !this.searchMode) {
          return;
        }
        await this.enrichOneSearchItem(item);
      }
    };
    const workers: Promise<void>[] = [];
    const n: number = Math.min(SEARCH_ENRICH_CONCURRENCY, targets.length);
    for (let i = 0; i < n; i++) {
      workers.push(worker());
    }
    Promise.all(workers).catch((): void => {});
  }

  /** 补齐单条：拉详情 → 合并进池；失败保留原样 */
  private async enrichOneSearchItem(item: ThreadItem): Promise<void> {
    try {
      const result: ThreadDetailResult = await TiebaService.getInstance()
        .fetchThreadDetail(item.tid, 1, 0, false, `${item.forumId ?? ''}`, 0);
      const d: ThreadDetail | undefined = result?.detail;
      if (d !== undefined && d !== null) {
        this.applySearchDetail(item.tid, d);
      }
    } catch (e) {
      // 单条失败不影响其它条目
    }
  }

  /** 详情结果合并进搜索池（只补空缺、不降级已有值），以新数组引用触发刷新 */
  private applySearchDetail(tid: string, d: ThreadDetail): void {
    let hit: boolean = false;
    for (const t of this.searchPool) {
      if (t.tid !== tid) {
        continue;
      }
      hit = true;
      if ((t.authorId ?? '').length === 0 && (d.authorId ?? '').length > 0) {
        t.authorId = d.authorId;
      }
      if ((t.authorAvatar ?? '').length === 0 && (d.authorAvatar ?? '').length > 0) {
        t.authorAvatar = d.authorAvatar;
      }
      if (d.author.length > 0 && (t.author.length === 0 || t.author === '贴吧用户')) {
        t.author = d.author;
      }
      if ((t.forumId ?? '').length === 0) {
        t.forumId = d.forumId;
      }
      if ((t.forumAvatar ?? '').length === 0 && (d.forumAvatar ?? '').length > 0) {
        t.forumAvatar = d.forumAvatar;
      }
      t.replyNum = d.replyNum;
      t.likeCount = d.likeCount ?? 0;
      t.isLiked = d.isLiked ?? false;
      if ((t.postId ?? '').length === 0 && (d.postId ?? '').length > 0) {
        t.postId = d.postId;
      }
      if ((t.images ?? []).length === 0 && (d.images ?? []).length > 0) {
        t.images = d.images;
        t.firstImage = d.images[0];
      }
      if ((t.abstract ?? '').length === 0 && d.contentText.length > 0) {
        t.abstract = d.contentText.replace(/\s+/g, ' ').trim().substring(0, 120);
      }
      break;
    }
    if (hit) {
      this.searchPool = this.searchPool.slice();
      this.searchPoolVersion++;
    }
  }

  /** 把一页扫描结果去重并入搜索池，返回新增项 */
  private mergeSearchPage(list: ThreadItem[]): ThreadItem[] {
    const seen: Set<string> = new Set<string>();
  for (const t of this.searchPool) {
      seen.add(t.tid);
    }
    const appended: ThreadItem[] = [];
    for (const t of list) {
      if (!seen.has(t.tid)) {
        seen.add(t.tid);
        appended.push(t);
      }
    }
    if (appended.length === 0) {
      return appended;
    }
    this.searchPool = this.searchPool.concat(appended);
    this.searchPoolVersion++;
    return appended;
  }

  /**
   * 搜索结果：服务端模式直接返回服务端命中（含正文命中，本地再过滤会误删命中）；
   * 本地模式按「标题命中优先、其次摘要（内容）命中」过滤池，带缓存（键 = 关键词 + 池版本）。
   */
  private searchThreads(): ThreadItem[] {
    const kw: string = this.searchKeyword.trim().toLowerCase();
    if (kw.length === 0) {
      return [];
    }
    if (this.searchServerMode) {
      return this.searchPool;
    }
    const key: string = `${kw}|${this.searchPoolVersion}`;
    if (key === this.searchCacheKey) {
      return this.searchCacheResult;
    }
    const titleHit: ThreadItem[] = [];
    const contentHit: ThreadItem[] = [];
    for (const t of this.searchPool) {
      if (t.title.toLowerCase().includes(kw)) {
        titleHit.push(t);
      } else if ((t.abstract ?? '').toLowerCase().includes(kw)) {
        contentHit.push(t);
      }
    }
    const result: ThreadItem[] = titleHit.concat(contentHit);
    this.searchCacheKey = key;
    this.searchCacheResult = result;
    return result;
  }

  /** 搜索进度文案：让"找到多少、扫了多少"可见，避免被误认为卡住 */
  private searchStatusText(): string {
    const found: number = this.searchThreads().length;
    if (this.searchServerMode) {
      if (this.searchFetching) {
        return `正在搜索本吧… 已找到 ${found} 条`;
      }
      if (this.searchExhausted) {
        return `已找到 ${found} 条 · 已到结果末尾`;
      }
      return `已找到 ${found} 条 · 下滑加载更多`;
    }
    const scanned: number = this.searchPool.length;
    if (this.searchFetching) {
      return `正在扫描本吧… 已找到 ${found} 条 · 已扫描 ${scanned} 帖`;
    }
    if (this.searchExhausted) {
      return this.searchScannedPages >= SEARCH_SCAN_MAX_PAGES
        ? `已找到 ${found} 条 · 已扫描 ${scanned} 帖（本吧帖量过大，已停止扫描）`
        : `已找到 ${found} 条 · 已搜索本吧全部 ${scanned} 帖`;
    }
    return `已找到 ${found} 条 · 下滑继续搜索`;
  }

  /** 无结果时的补充说明（区分服务端无命中 / 本地扫到底 / 扫到上限） */
  private searchEmptyHint(): string {
    if (this.searchServerMode) {
      return '本吧没有匹配的帖子';
    }
    if (this.searchScannedPages >= SEARCH_SCAN_MAX_PAGES) {
      return `已扫描 ${this.searchPool.length} 帖仍未找到匹配`;
    }
    return `已搜索本吧全部 ${this.searchPool.length} 帖`;
  }

  /** 结果列表底部文案（有结果但已取完，与服务端"无命中"区分开） */
  private searchFooterEndText(): string {
    if (this.searchServerMode) {
      return '已到结果末尾';
    }
    return this.searchScannedPages >= SEARCH_SCAN_MAX_PAGES
      ? `已扫描 ${this.searchPool.length} 帖（本吧帖量过大，已停止扫描）`
      : `已搜索本吧全部 ${this.searchPool.length} 帖`;
  }

  private openForum(forumName: string, forumId: string = ''): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ThreadList',
      params: { kw: forumName, forumName: forumName, fid: forumId }
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '贴吧打开失败，请稍后重试' });
    });
  }

  private formatNumber(num: number): string {
    if (num >= 10000) {
      return (num / 10000).toFixed(1).replace('.0', '') + 'W';
    }
    if (num >= 1000) {
      return (num / 1000).toFixed(1).replace('.0', '') + 'K';
    }
    return `${num}`;
  }

  /**
   * 数据请求真实下发的 sortType（数据侧唯一真源）：仅「最新」档被子档 latestSortMode 改写，
   * 热门（0）/ 精选（2）原样。UI 段（底栏三钮高亮、横滑手势、selectedSort === 2 精选分支）一律不用本函数。
   */
  private effectiveSort(): number {
    return this.selectedSort === 1 ? this.latestSortMode : this.selectedSort;
  }

  /** 「最新」档子排序持久化（全局档，全局 0/1；失败静默不影响功能） */
  private saveLatestSortMode(): void {
    CacheManager.getInstance().put(CACHE_KEY.LATEST_SORT_MODE, String(this.latestSortMode)).catch(() => {
    });
  }

  /** 子排序点选入口：持久化 + toast + 重新加载（走快照/缓存/网络三层，enterDir=0 直上屏路径） */
  private applyLatestSort(mode: number): void {
    if (this.latestSortMode === mode) {
      return;
    }
    this.latestSortMode = mode;
    this.saveLatestSortMode();
    this.page = 1;
    this.hasMore = true;
    this.stalledPages = 0;
    this.listScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    this.loadThreads();
  }

  /**
   * 数据归属键（缓存 key / 页内快照 key / 竞态判定共用真源）：
   * 「热门」档走客户端热度榜（TiebaService.fetchForumHotRank），内容集与「最新·按回复时间」
   * （服务端 sort_type 0 原样时间序）**不同** —— 二者必须分键，否则缓存与快照会互相污染。
   */
  private sortKey(): string {
    if (this.selectedSort === 0) {
      return 'hot';
    }
    return `${this.effectiveSort()}`;
  }

  /** 指定归属键的列表缓存 key（省略时取当前档；预热其它排序时显式传入 'hot' / '0' / '1' / '2'） */
  private forumCacheKey(key?: string): string {
    const k: string = key === undefined ? this.sortKey() : key;
    return `${CACHE_KEY.FORUM_LIST}_${this.forumName}_${k}`;
  }

  /**
   * threads 更新时同步页内会话快照（@Watch）：空数组/骨架屏期不覆盖，
   * 保留最近一份完整数据，使切回该排序可 0 开销直出。
   */
  private onThreadsChanged(): void {
    // WaterFlow 数据源同步（§4.8 决策 13）：放在空列表短路之前，保证「清空」也能同步到数据源
    this.syncListDataSource();
    if (this.threads.length === 0) {
      return;
    }
    // 归属隔离：sortSession key 用 sortKey()（'hot' / 0=回复 / 1=发帖 / 2=精选）——
    // 热门榜与「最新·按回复时间」同为服务端 sort 0，必须分键，否则快照互相覆盖
    this.sortSession.set(this.sortKey(), {
      threads: this.threads,
      page: this.page,
      hasMore: this.hasMore,
      ts: Date.now(),
    });
  }

  /**
   * WaterFlow 数据（§4.8 决策 13）：置顶卡排在前面，其余按原顺序。
   * 「精选」tab（sort=2）不分置顶/普通，直接给全量。
   * 置顶卡作为瀑布流的**普通格子**渲染（不拉伸，自然高度）。
   */
  private waterFlowThreads(): ThreadItem[] {
    if (this.selectedSort === 2) {
      return this.threads;
    }
    // 复用置顶 / 普通拆分缓存（语义等价：isTop===true 全量后接 isTop!==true 全量），
    // 避免同一份 threads 在「同步数据源」与「渲染置顶区」两条路径上被重复全量过滤。
    return this.pinnedThreads().concat(this.normalThreads());
  }

  /**
   * 数据源通用同步（全量替换或尾部追加）。
   * 判定「尾部追加」必须**逐项比对前缀**：只比长度会把「切排序 / 刷新后列表变长」误判成追加，
   * 于是 WaterFlow 只重建尾段、前段仍渲染旧内容（真机表现为排序切换后列表内容错乱）。
   */
  private syncSourceData(src: ThreadListDataSource, next: ThreadItem[]): void {
    const old: ThreadItem[] = src.data;
    const oldLen: number = old.length;
    let isAppend: boolean = oldLen > 0 && next.length > oldLen;
    if (isAppend) {
      for (let i: number = 0; i < oldLen; i++) {
        if (next[i].tid !== old[i].tid) {
          isAppend = false;
          break;
        }
      }
    }
    // P1-1（2026-09-29 丢帧治理）：**等长同序**（返回本页 / 静默刷新拿到同一批数据）改走就地更新，
    // 只对引用真正变化的项 notifyChange，不再整表 onDataReloaded 推倒重来。
    // 真机实测依据：进入吧主页首个窗口 fps 69~81 / d33 1~2；且**二次进入（图片全命中、img0）
    // 依然 fps 69** —— 证明成本来自整表重建而非图片下载/解码。
    // 与 HomeTab.syncSource 同口径（该页早已具备此分支，本页此前缺失，两页不同构）。
    // 长度变化一律走原路径（变长=追加；变短/换血=整表 reload），不做长度无关的模糊匹配。
    if (!isAppend && oldLen === next.length) {
      let sameOrder: boolean = true;
      for (let i: number = 0; i < next.length; i++) {
        if (next[i].tid !== old[i].tid) {
          sameOrder = false;
          break;
        }
      }
      if (sameOrder) {
        src.data = next;
        const updates: DataChangeOperation[] = [];
        for (let i: number = 0; i < next.length; i++) {
          if (next[i] !== old[i]) {
            updates.push({ type: DataOperationType.CHANGE, index: i });
          }
        }
        if (updates.length > 0) {
          src.notify(updates);
          PerfTrace.mark('listTouch');
        }
        return;
      }
    }
    src.data = next;
    if (isAppend) {
      src.notify([{ type: DataOperationType.ADD, index: oldLen, count: next.length - oldLen }]);
    } else {
      PerfTrace.mark('listSwap');
      src.notify([{ type: DataOperationType.RELOAD }]);
    }
  }

  /** 把合并后的列表同步进 WaterFlow 数据源（单列/多列共用） */
  private syncListDataSource(): void {
    // 打点口径收口到 syncSourceData 的分支内部（swap=整表重建 / touch=逐项就地更新）
    const next: ThreadItem[] = this.waterFlowThreads();
    this.syncSourceData(this.listDataSource, next);
    // 窗口化挂载：列表缩短 = 刷新/切吧换血 → 窗口回首屏（追加只会变长，不受影响）
    if (next.length < this.listDataSource.data.length) {
      this.slotReset();
    }
    // FSTAT 深度关联打点（2026-09-28 量化「越滑越卡」）：列表条数变化即打一行，与帧统计按时间对齐
    console.info(`[FSTAT] listN=${next.length}`);
    // 数据量变化 → 主体 section 的 itemsCount 必须同步（数量不匹配会让 WaterFlow 无法滚动）
    this.syncSections();
    this.scheduleListPrefetch();
  }

  /** 加载态变化 → 主体格子数变化（骨架屏 / 空态 / 错误视图各占 1 格） */
  private onLoadStateChanged(): void {
    this.syncSections();
  }

  /**
   * 同步 WaterFlow 的分段配置（§4.8 T-G 修正）：吧头作为**跨列的首个格子**参与滚动。
   * - section 0：吧头，`crossCount: 1` → 独占整行（全宽）
   * - section 1：主体，`crossCount: 3/4` → 帖子多列；左右各留 12 边距（与单列档视觉一致）
   *
   * 官方约束（必须遵守）：各 section 的 `itemsCount` 累计和 **必须等于** `WaterFlow` 的实际子节点数，
   * 否则组件无法正常滚动 → 数据源 / 列数 / 加载态任一变化后都要重新调用本方法。
   * `onGetItemMainSizeByIndex` 一律不设置（文档要求不得跨 section 混用），由 `FlowItem` 自适应高度。
   */
  private syncSections(): void {
    const cols: number = this.threadColumns();
    const isSuccess: boolean = this.loadState === LoadState.Success;
    // 主体 section：成功态 = 帖子（至少 1 项，规避 itemsCount 为 0）；
    // 其余态 = 1 项、单列（骨架屏 / 空态 / 错误视图需占满整行，不能只占一列）。
    // 单列档（cols<=1）与多列档同构：吧头 1 格 + 主体 bodyCount 格（crossCount 1），
    // 置顶卡作为主体的普通格子渲染（§4.8 决策 13）——不再拆「置顶块 / 普通帖」独立 section
    //（2026-09-24 回退：跨 section 虚拟化在真机上出现整层不渲染，对齐 docs/floor-vanish-viewport-fix.md
    //  的同类结论，恢复单一数据源口径）。
    const bodyCount: number = isSuccess ? Math.max(this.listDataSource.data.length, 1) : 1;
    const bodyCross: number = isSuccess ? cols : 1;
    // 去重：切排序时本方法会被「数据源同步」「加载态回调」先后调两次，配置未变则直接返回，
    // 避免同一帧内重复 splice 触发 WaterFlow 重排（真机表现为过场中画面一顿/闪）。
    const key: string = `s${cols}_${bodyCount}_${bodyCross}_m${this.cardSideInset()}`;
    if (key === this.lastSectionKey) {
      return;
    }
    this.lastSectionKey = key;
    const next: SectionOptions[] = [
      { itemsCount: 1, crossCount: 1 },
      { itemsCount: bodyCount, crossCount: bodyCross, margin: { left: this.cardSideInset(), right: this.cardSideInset() } },
    ];
    this.sections.splice(0, this.sections.length(), next);
  }

  /** 吧内帖子卡左右留白：与全 App 其它页面同源同值（直接读「左右留白」设置，不再保留历史 -4 偏移） */
  private cardSideInset(): number {
    return Math.max(0, this.pageMargin);
  }

  /**
   * 排序过场位移量（vp）：`inOffset` 是百分比语义（±100），换算成「整屏平移」。
   * 多列档下卡片宽只有 1/3~1/4 屏，`translate` 直接写百分比会位移不足（卡片从半屏处冒出），
   * 故统一用 vp 数值；宽度取根容器实测值，取不到时退回屏幕宽（分屏 / 折叠态更准）。
   */
  private sortShiftX(): number {
    const w: number = this.currentWidth > 0 ? this.currentWidth : this.pageWidth;
    return this.inOffset * w / 100;
  }

  /**
   * 骨架屏→内容交叉淡入淡出（方案A）：
   * animateTo 内同时让内容 0→1、骨架屏 1→0；动画结束后再把 loadState 落定到 target，
   * 使骨架屏分支移除时已完全透明，消除"骨架屏瞬间消失+内容瞬间整体出现"的生硬感。
   * target 用于区分 Success / Empty（空吧）。
   * 已淡入完成（缓存秒开/静默刷新/排序切换）时直接落定目标态，避免重复动画。
   */
  private fadeInContent(target: LoadState = LoadState.Success): void {
    if (this.contentOpacity >= 1) {
      if (this.loadState === LoadState.Loading) {
        this.loadState = target;
      }
      return;
    }
    animateTo({ duration: 250, curve: Curve.EaseInOut }, () => {
      this.contentOpacity = 1;
      this.skeletonOpacity = 0;
    });
    const token: number = this.loadToken;
    setTimeout(() => {
      if (token === this.loadToken && this.loadState === LoadState.Loading) {
        this.loadState = target;
      }
    }, 260);
  }

  /**
   * 收口排序过场：清掉收口定时器 → 位移归零 → 释放旧页快照。
   * 快速连切时先调用（上一次动画可能正跑到一半），复位后再由 `applySortDisplay` 摆新起点。
   */
  private clearSortSettle(): void {
    if (this.sortSettleTimer !== -1) {
      clearTimeout(this.sortSettleTimer);
      this.sortSettleTimer = -1;
    }
    this.inOffset = 0;
    this.outOffset = 0;
    this.exitSnapshot = null;
    this.exitClipTop = 0;
  }

  /**
   * 注册过场收口：动画播完后卸载旧页快照并复位位移。
   * （`animateTo` 无结束回调，与首页 `switchTab` 一样用定时器兜底；时长取动画的约 1.3 倍，
   *   让弹簧末段的回弹也播完再收，避免旧页被提前抽走。）
   */
  private scheduleSortSettle(): void {
    if (this.sortSettleTimer !== -1) {
      clearTimeout(this.sortSettleTimer);
    }
    this.sortSettleTimer = setTimeout(() => {
      this.sortSettleTimer = -1;
      this.inOffset = 0;
      this.outOffset = 0;
      this.exitSnapshot = null;
      this.exitClipTop = 0;
    }, SORT_ANIM_SETTLE);
  }

  /**
   * 截取旧页：把当前屏幕上的**列表区**（旧排序的内容 + 它的滚动位置）同步截成 PixelMap，供过场里滑出的那一层使用。
   *
   * 用 `getSync` 是刻意的：异步版要等回调，而页内快照是**同步命中**的 —— 异步截图赶不上同一帧起滑，
   * 旧页会在动画中途才冒出来（闪一下，比不做更糟）。同步截图取的是上一帧已渲染的成品，
   * 不触发重新布局、不改动任何几何，耗时在点击这一帧内消化。
   *
   * 裁剪（2026-09-12）：位移只作用于列表区、吧头是静止的，若旧页快照仍带着吧头，旧页滑出时吧头会跟着滑。
   * 故按 `SnapshotOptions.region` 把吧头顶部裁掉 —— 边界 y = 「顶栏让位 + 吧头块高 − 当前滚动偏移」，
   * 即吧头块底边在 Scroll 视口里的位置；快照层再按同一个值下移，正好落在列表区上（见旧页 Image 层）。
   * 该值 ≤ 0（吧头已滚出屏幕上方）或吧头高尚未测到 → 不裁，整屏即列表内容，与调整前行为一致。
   * region 的四个值单位是 **px**（vp2px），且取值必须落在组件矩形内，故对宽高做了保护。
   *
   * 失败（组件未就绪 / 平台不支持）时静默降级为 null —— 过场退化成"只有新页滑入"，功能不受影响。
   */
  private captureExitSnapshot(): void {
    // 裁剪边界：吧头块底边在滚动视口里的 y（vp）。吧头高未测到时不裁，避免旧页内容整体错位。
    // 单列 / 多列同款：多列档的吧头由「等量反向位移」抵消（见吧头 FlowItem），转场中同样静止，
    // 故旧页快照同样要裁掉吧头 —— 否则旧页滑出时吧头会跟着滑，与静止的新页吧头重叠。
    // 滚动容器在 Refresh 内，Refresh 的上边距为顶栏预留空间。
    // 容器局部坐标里首项即吧头，裁剪边界 = 「吧头块底边 − 滚动偏移」
    const listTop: number = this.headerBlockH
      - this.listScroller.currentOffset().yOffset;
    const clipTop: number = (this.headerBlockH > 0 && this.viewportH > 0)
      ? Math.max(0, Math.min(listTop, this.viewportH)) : 0;
    this.exitClipTop = clipTop;
    try {
      if (clipTop > 0 && this.viewportW > 0) {
        const ui = this.getUIContext();
        // region 四边均为 px，且必须落在 [0, 组件宽/高] 区间内（否则截图报错）
        const region: componentSnapshot.SnapshotRegion = {
          left: 0,
          top: ui.vp2px(clipTop),
          right: ui.vp2px(this.viewportW),
          bottom: ui.vp2px(this.viewportH)
        };
        const options: componentSnapshot.SnapshotOptions = { region: region };
        this.exitSnapshot = componentSnapshot.getSync(THREAD_SCROLL_SNAPSHOT_ID, options);
        console.info(`[SORT] exit snapshot captured clipTop=${clipTop} headerH=${this.headerBlockH}`);
      } else {
        // 吧头不在屏内（或尚未测到）：整屏都是列表内容，无需裁剪
        this.exitSnapshot = componentSnapshot.getSync(THREAD_SCROLL_SNAPSHOT_ID);
        console.info(`[SORT] exit snapshot captured (full) clipTop=${clipTop} headerH=${this.headerBlockH}`);
      }
    } catch (e) {
      // 截图不可用（组件未就绪 / 平台限制）：降级为"只有新页滑入"，并在日志里留下线索
      this.exitSnapshot = null;
      console.warn(`[SORT] exit snapshot failed: ${(e as BusinessError).message ?? e}`);
    }
  }

  /**
   * 排序数据上屏（唯一入口）：**同一帧**完成「替换数据 + 回顶 + 双页对向起滑」。
   *
   * 与首页 `switchTab` 逐项同款：新页先无动画摆到对侧（`inOffset = dir * 100`）、旧页快照摆在
   * 原位（`outOffset = 0`），紧接着在同一个调用栈里 `animateTo` —— 新页归零、旧页跑到反侧，
   * 两页在同一段时间里对向平移、屏幕上始终相接，这就是"两个界面仿佛连着"的观感来源。
   * 位移只作用在「列表区」这一层（吧头、顶栏、底栏静止），旧页来自 `captureExitSnapshot`
   * （点击那一刻的列表区），所以它的内容与滚动位置天然正确。
   *
   * 未命中缓存（`state = Loading`）时改落骨架屏：不走双页过场（半透明骨架块与旧页叠映反而脏），
   * 直接收口过场 + 骨架屏轻淡入，等网络返回再走双页过场。
   * 换排序 = 换内容集，列表同步无动画回顶（保留旧偏移对新排序没有意义）。
   */
  private applySortDisplay(d: SortDisplay): void {
    // 竞态：数据归属键已不是当前档（快速连点 / 最新档内子档切换 / 热门↔按回复时间切换），丢弃
    if (d.key !== this.sortKey()) {
      return;
    }
    this.page = d.page;
    this.hasMore = d.hasMore;
    if (d.state === LoadState.Loading) {
      // 未命中缓存：收口过场（旧页不再需要）+ 骨架屏轻淡入，等网络返回再对向平移
      this.clearSortSettle();
      this.threads = [];
      this.loadState = LoadState.Loading;
      this.contentOpacity = 0;
      this.getUIContext().animateTo({ duration: SORT_SKELETON_FADE, curve: Curve.EaseOut }, () => {
        this.skeletonOpacity = 1;
      });
      return;
    }
    const dir: number = this.enterDir !== 0 ? this.enterDir : 1;
    this.enterDir = 0;
    this.threads = d.threads;
    this.loadState = d.state;
    this.listScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    // 起点态（无动画赋值）：新页在对侧整屏外、旧页快照留原位待退场 —— 与首页 switchTab 写法一致
    this.inOffset = dir * 100;
    this.outOffset = 0;
    this.contentOpacity = 1;
    this.sortAnimUntil = Date.now() + SORT_ANIM_SETTLE;
    this.getUIContext().animateTo({ duration: SORT_ANIM_DURATION, curve: curves.springMotion(0.72, 0.86) }, () => {
      this.inOffset = 0;
      this.outOffset = -dir * 100;
      this.skeletonOpacity = 0;
    });
    // 动画收口：卸载旧页快照 + 复位位移（快速连切时会被下一次切换先行清掉）
    this.scheduleSortSettle();
  }

  /**
   * 吧列表加载：stale-while-revalidate 秒开——本地快照（5 分钟新鲜度）无论是否过期都先显示，
   * 后台静默刷新保持数据新鲜；无缓存时网络请求后立即渲染，昵称校准全部后台不阻塞首屏。
   */
  async loadThreads(forceRefresh: boolean = false): Promise<void> {
    // 请求代际递增：使 in-flight 的加载更多结果作废，避免 concat 到重置后的新列表（刷新/排序切换）
    const myToken: number = ++this.loadToken;
    this.lastPrefetchPage = -1;
    this.loadMoreFailed = false;
    // 预取节流基线同步复位：刷新 / 切排序后列表与内容高整体换新，沿用旧偏移基线会漏触发
    this.prefetchGate.reset();
    // 快照本次请求的归属键（热门='hot' 热度榜 / 其余=生效排序）：期间用户切档会再次触发 loadThreads，
    // 返回时据此丢弃过期结果；同时记下「是否首屏」用于缓存回写（热门首屏一次消费 HOT_RANK_PAGES 页，
    // 分页游标 page 在请求返回后会被推进，故必须在请求前判定）
    const myKey: string = this.sortKey();
    const isHotRank: boolean = this.selectedSort === 0;
    const isFirstLoad: boolean = this.page <= 1;
    if (!forceRefresh && this.page === 1) {
      // 页内会话快照命中（本次进吧期间刚看过该排序）：0 开销秒开，数据足够新不做后台刷新
      const session = this.sortSession.get(myKey);
      if (session && session.threads.length > 0 && Date.now() - session.ts < SORT_SESSION_TTL) {
        this.stalledPages = 0;
        if (this.enterDir !== 0) {
          // 排序切换命中页内快照（快照命中在本 async 函数的第一段、同步执行）：同帧替换 + 起滑
          this.applySortDisplay({
            key: myKey, threads: session.threads,
            page: session.page, hasMore: session.hasMore, state: LoadState.Success,
          });
        } else {
          this.threads = session.threads;
          this.page = session.page;
          this.hasMore = session.hasMore;
          this.loadState = LoadState.Success;
          // 首次进入/重试且透明度尚未就绪时平滑淡入（已就绪则 fadeInContent 直接落定，无副作用）
          this.fadeInContent(LoadState.Success);
        }
        return;
      }
      try {
        // 与首页推荐流同构：过期缓存也返回（stale-while-revalidate），保证任何时刻重进该吧都秒开
        const cached = await CacheManager.getInstance().getWithTtlAllowStale<ForumListCache>(this.forumCacheKey());
        if (myToken !== this.loadToken || myKey !== this.sortKey()) {
          return;
        }
        if (cached && cached.data.threads.length > 0) {
          if (cached.data.forumInfo) {
            this.forumInfo = cached.data.forumInfo;
          }
          this.page = cached.data.page ?? (isHotRank ? HOT_RANK_PAGES : 1);
          this.hasMore = cached.data.hasMore ?? true;
          this.stalledPages = 0;
          // 命中缓存（含过期 TTL）：秒开显示，后台静默刷新保持数据新鲜；刷新失败保留旧内容
          this.refreshSilently();
          if (this.enterDir !== 0) {
            // 排序切换命中本地缓存：同帧替换 + 起滑（与首页 Tab 切换同一形态）
            this.applySortDisplay({
              key: myKey, threads: cached.data.threads,
              page: this.page, hasMore: this.hasMore, state: LoadState.Success,
            });
          } else {
            this.threads = cached.data.threads;
            this.loadState = LoadState.Success;
            // 内容淡入（首次进入时 contentOpacity=0 → 平滑淡入）
            this.fadeInContent(LoadState.Success);
          }
          // 首次成功展示后后台预热其它两个排序，使后续切换首次即命中缓存（一次性，失败静默）
          this.warmupSortCaches();
          return;
        }
      } catch (_) {
        // 缓存读取失败则走正常网络加载
      }
    }
    if (myToken !== this.loadToken || myKey !== this.sortKey()) {
      return;
    }
    if (this.enterDir !== 0) {
      // 排序切换未命中缓存：落骨架屏（轻淡入）等网络返回，返回后由 applySortDisplay 滑入
      this.applySortDisplay({
        key: myKey, threads: [], page: this.page, hasMore: true, state: LoadState.Loading,
      });
    } else {
      this.loadState = LoadState.Loading;
      // 首次进入/重试：复位可能残留的过场位移与旧页快照，骨架屏从正确位置出现
      this.inOffset = 0;
      this.outOffset = 0;
      this.exitSnapshot = null;
      // 每次加载重置过渡透明度：骨架屏覆盖、内容透明，等待淡入
      this.contentOpacity = 0.0;
      this.skeletonOpacity = 1.0;
    }
    try {
      // 热门档：并发抓 HOT_RANK_PAGES 页成「客户端热度榜」（与「最新·按回复时间」区分开）；
      // 其余档：预取合流版（page=1/sort=0 且点击时已起跑预取则直接消费，不另发一次请求）
      const result = isHotRank
        ? await TiebaService.getInstance().fetchForumHotRank(this.forumName)
        : await TiebaService.getInstance().fetchForumThreadsCoalesced(this.forumName, this.page, this.effectiveSort(), false);
      // 竞态防护：请求期间用户已切换档/刷新，丢弃晚归结果，避免旧内容覆盖当前列表
      if (myToken !== this.loadToken || myKey !== this.sortKey()) {
        return;
      }
      this.stalledPages = 0;
      // 热门榜本次已消费 HOT_RANK_PAGES 页：分页游标推进到已聚合页数，后续 loadMore 从下一页续接（时间序）
      if (isHotRank) {
        this.page = HOT_RANK_PAGES;
      }
      if (this.enterDir !== 0) {
        // 排序切换（未命中缓存）：网络返回后同帧替换 + 起滑
        this.applySortDisplay({
          key: myKey, threads: result.list, page: this.page,
          hasMore: result.list.length > 0,
          state: result.list.length > 0 ? LoadState.Success : LoadState.Empty,
        });
      } else {
        this.hasMore = result.list.length > 0;
        this.threads = result.list;
        // 不直接切走 Loading：先让骨架屏淡出，动画结束后由 fadeInContent 落定目标态
        this.fadeInContent(result.list.length > 0 ? LoadState.Success : LoadState.Empty);
      }
      // 首次成功展示后后台预热其它两个排序，使后续切换首次即命中缓存（一次性，失败静默）
      this.warmupSortCaches();
      const header = TiebaService.getInstance().getCachedForumHeader(this.forumName);
      if (header) {
        this.forumInfo = header;
      }
      // 昵称后台校准，不阻塞首屏渲染
      if (result.list.length > 0) {
        this.enrichInBackground(result.list);
      }
      if (isFirstLoad && result.list.length > 0) {
        this.saveForumCache(result.list);
      }
      // Auto-load more if content is too short to fill the screen
      if (this.hasMore && result.list.length > 0 && result.list.length < 8) {
        this.autoLoadMore();
      }
    } catch (e) {
      if (myToken !== this.loadToken || myKey !== this.sortKey()) {
        return;
      }
      // 失败也要收口过场：否则新页会停在侧偏位置，错误页跟着歪在一边
      this.enterDir = 0;
      this.clearSortSettle();
      this.contentOpacity = 1;
      this.loadState = LoadState.Error;
      this.errorMsg = (e as Error).message ?? '加载失败';
    }
  }

  /** 缓存命中后的后台静默刷新：更新列表与吧头，成功后回写缓存 */
  private refreshSilently(): void {
    // 竞态防护：静默刷新期间用户可能已切换档/刷新（代际/归属键变化），返回后丢弃过期结果
    const myToken: number = this.loadToken;
    const myKey: string = this.sortKey();
    const currentPage: number = this.page;
    const isHotRank: boolean = this.selectedSort === 0;
    const task: Promise<PagedResult<ThreadItem>> = isHotRank
      ? TiebaService.getInstance().fetchForumHotRank(this.forumName)
      : TiebaService.getInstance().fetchForumThreadsCoalesced(this.forumName, 1, this.effectiveSort(), false);
    task.then((result) => {
      if (myToken !== this.loadToken || myKey !== this.sortKey() || result.list.length === 0 ||
        this.refreshing || this.loadingMore || this.page !== currentPage || this.lastScrollY > 0) {
        return;
      }
      // 排序切换的过场窗口内（`SORT_ANIM_SETTLE` ≈ 420ms）：只回写缓存、不上屏 ——
      // 否则两页对向平移的途中列表内容会被静默刷新整块替换，出现"滑到一半内容变了"的跳变。
      // 丢弃的这次上屏由下一次切换 / 下拉刷新补上，缓存不受影响。
      if (this.enterDir !== 0 || Date.now() < this.sortAnimUntil) {
        this.saveForumCache(result.list, myKey, isHotRank ? HOT_RANK_PAGES : 1, true);
        return;
      }
      this.page = isHotRank ? HOT_RANK_PAGES : 1;
      this.hasMore = result.list.length > 0;
      this.threads = result.list;
      this.stalledPages = 0;
      const header = TiebaService.getInstance().getCachedForumHeader(this.forumName);
      if (header) {
        this.forumInfo = header;
      }
      this.enrichInBackground(result.list);
      this.saveForumCache(result.list);
    }).catch((e: Error) => {
      // 静默刷新失败保留缓存内容展示，仅记录日志
      console.info(`[ThreadList] silent refresh fail: ${e.message}`);
    });
  }

  /** 后台昵称校准：拉取 profile 确认昵称后按 authorId 局部替换，不阻塞首屏 */
  private enrichInBackground(list: ThreadItem[]): void {
    // 竞态防护：昵称校准返回后若已切换排序/刷新，跳过 diff，避免昵称 map 串台到其它排序列表
    const myToken: number = this.loadToken;
    const mySort: number = this.selectedSort;
    TiebaService.getInstance().enrichHomeAuthors(list).then((enriched: ThreadItem[]) => {
      if (myToken === this.loadToken && mySort === this.selectedSort) {
        this.applyEnrichedAuthors(enriched);
      }
    }).catch((_: Error) => {
      // 校准失败保留接口昵称，不影响列表展示
    });
  }

  /** 将校准结果按 authorId diff 更新到当前列表与搜索池（兼容校准期间已加载更多） */
  private applyEnrichedAuthors(enriched: ThreadItem[]): void {
    const nameMap: Map<string, string> = new Map<string, string>();
    for (const e of enriched) {
      const id: string = `${e.authorId ?? ''}`;
      if (id.length > 0 && e.author.length > 0) {
        nameMap.set(id, e.author);
      }
    }
    if (nameMap.size === 0) {
      return;
    }
    const updatedThreads: ThreadItem[] = this.remapAuthorNames(this.threads, nameMap);
    if (updatedThreads !== this.threads) {
      this.threads = updatedThreads;
    }
    // 搜索池内的条目同样需要校准（池独立于列表，否则搜索结果会保留占位昵称）
    if (this.searchMode) {
      const updatedPool: ThreadItem[] = this.remapAuthorNames(this.searchPool, nameMap);
      if (updatedPool !== this.searchPool) {
        this.searchPool = updatedPool;
        this.searchPoolVersion++;
      }
    }
  }

  /** 按 authorId → 昵称 映射重写一组帖子的昵称；无变化时原样返回（列表与搜索池共用） */
  private remapAuthorNames(list: ThreadItem[], nameMap: Map<string, string>): ThreadItem[] {
    let changed: boolean = false;
    const updated: ThreadItem[] = list.map((t: ThreadItem): ThreadItem => {
      const id: string = `${t.authorId ?? ''}`;
      const nick: string | undefined = nameMap.get(id);
      if (nick !== undefined && nick.length > 0 && nick !== t.author) {
        changed = true;
        return {
          tid: t.tid, postId: t.postId, forumId: t.forumId, title: t.title, forumName: t.forumName,
          forumAvatar: t.forumAvatar, author: nick, authorId: t.authorId, authorAvatar: t.authorAvatar,
          authorNameShowMissing: t.authorNameShowMissing,
          replyNum: t.replyNum, likeCount: t.likeCount, isLiked: t.isLiked, abstract: t.abstract,
          firstImage: t.firstImage, images: t.images, createTime: t.createTime, isTop: t.isTop,
          isGood: t.isGood, isFeatured: t.isFeatured
        } as ThreadItem;
      }
      return t;
    });
    return changed ? updated : list;
  }

  /** 写入吧列表快照缓存（含吧头信息）；key 省略时写当前档（sortKey），失败不影响功能 */
  private async saveForumCache(list: ThreadItem[], key?: string, page: number = this.page,
    hasMore: boolean = this.hasMore): Promise<void> {
    try {
      await CacheManager.getInstance().putWithTtl<ForumListCache>(
        this.forumCacheKey(key),
        { threads: list, forumInfo: this.forumInfo, page: page, hasMore: hasMore },
        CACHE_TTL.FORUM_LIST
      );
    } catch (_) {
      // 缓存写入失败可忽略
    }
  }

  /**
   * 排序冷缓存预热：首次成功展示后，把其它两个排序（最新/精选）提前拉好写入本地缓存，
   * 使后续首次切换直接命中缓存秒开。已有新鲜缓存（5 分钟内）则跳过，不重复消耗流量。
   * 纯后台执行，失败静默；warmupStarted 保证每次进吧只跑一轮。
   */
  private async warmupSortCaches(): Promise<void> {
    if (this.warmupStarted) {
      return;
    }
    this.warmupStarted = true;
    // 预热目标 = 其它档位的归属键集合（'hot' 热门榜 / '0' 回复序 / '1' 发帖序 / '2' 精选）：
    // 热门榜与「最新·按回复时间」内容集不同、缓存分键，故两者都要各自预热；
    // 剔除当前档后逐个预热，切档（含「最新」两个子档互换）首次即命中缓存秒开。
    const cur: string = this.sortKey();
    const targets: Set<string> = new Set<string>(['hot', '0', '1', '2']);
    targets.delete(cur);
    for (const key of targets) {
      try {
        const cached = await CacheManager.getInstance().getWithTtlAllowStale<ForumListCache>(this.forumCacheKey(key));
        if (cached && !cached.expired && cached.data.threads.length > 0) {
          continue;
        }
      } catch (_) {
        // 缓存检查失败照常尝试预热
      }
      this.warmupSort(key);
    }
  }

  /** 单个档位的预热请求：拉取首屏（'hot' 走客户端热度榜）并写本地缓存，失败不影响主流程 */
  private async warmupSort(key: string): Promise<void> {
    try {
      const result: PagedResult<ThreadItem> = key === 'hot'
        ? await TiebaService.getInstance().fetchForumHotRank(this.forumName, true)
        : await TiebaService.getInstance().fetchForumThreads(this.forumName, 1, parseInt(key, 10), false);
      if (result.list.length === 0 || key === this.sortKey()) {
        return;
      }
      await CacheManager.getInstance().putWithTtl<ForumListCache>(
        this.forumCacheKey(key),
        { threads: result.list, forumInfo: this.forumInfo, page: key === 'hot' ? HOT_RANK_PAGES : 1, hasMore: true },
        CACHE_TTL.FORUM_LIST
      );
      console.info(`[ThreadList] warmup key=${key} n=${result.list.length}`);
    } catch (e) {
      console.info(`[ThreadList] warmup key=${key} fail: ${(e as Error).message}`);
    }
  }

  /**
   * 加载下一页。
   * @param silent 后台预取路径（滚动预取）传 true：尾部先静默、超时才浮出 loading，失败也不打扰用户
   *               （由触底 / 滚动兜底重试）；用户显式路径（触底 onReachEnd、点击重试）保持默认 false：
   *               立即浮出 loading，失败给出可点重试。
   */
  async loadMore(silent: boolean = false): Promise<void> {
    if (this.loadingMore || this.refreshing || !this.hasMore ||
      (silent && (this.loadMoreFailed || this.lastPrefetchPage === this.page))) {
      return;
    }
    if (silent) {
      this.lastPrefetchPage = this.page;
    }
    this.loadingMore = true;
    this.beginLoadMoreHint(silent);
    // 记录当前代际：返回时若已刷新/切换排序则丢弃结果
    const myToken: number = this.loadToken;
    try {
      while (this.hasMore && myToken === this.loadToken) {
        const nextPage = this.page + 1;
        const result = await TiebaService.getInstance().fetchForumThreads(this.forumName, nextPage, this.effectiveSort(), false);
        if (myToken !== this.loadToken) {
          return;
        }
        // 这一页全是重复帖时，直接取下一页。mergePage 会限制连续无新增的页数。
        if (this.mergePage(nextPage, result.list) > 0) {
          break;
        }
      }
    } catch (e) {
      // 预加载失败静默忽略，靠 onReachEnd 兜底重试；仅用户主动触底时提示（并保留可点重试位）
      if ((!silent || this.loadingHintVisible) && myToken === this.loadToken) {
        this.loadMoreFailed = true;
        if (!silent) {
          this.getUIContext().getPromptAction().showToast({ message: '加载更多失败，请稍后重试' });
        }
      }
    } finally {
      this.loadingMore = false;
      this.endLoadMoreHint();
    }
  }

  /** 尾部加载提示起手：显式路径立即浮出；后台预取路径先静默，超时 LIST_LOAD_HINT_DELAY 才浮出 */
  private beginLoadMoreHint(silent: boolean): void {
    this.clearLoadingHintTimer();
    this.loadMoreFailed = false;
    if (!silent) {
      this.loadingHintVisible = true;
      return;
    }
    this.loadingHintVisible = false;
    this.loadingHintTimer = setTimeout(() => {
      this.loadingHintTimer = -1;
      this.loadingHintVisible = true;
    }, LIST_LOAD_HINT_DELAY);
  }

  /** 尾部加载提示收尾：清延时器 + 收回 loading（失败态由 loadMoreFailed 单独承载并保持可见） */
  private endLoadMoreHint(): void {
    this.clearLoadingHintTimer();
    this.loadingHintVisible = false;
  }

  /** 清理尾部提示延时器（beginLoadMoreHint 重排前 + aboutToDisappear 退页时调用） */
  private clearLoadingHintTimer(): void {
    if (this.loadingHintTimer !== -1) {
      clearTimeout(this.loadingHintTimer);
      this.loadingHintTimer = -1;
    }
  }

  /**
   * 用户已触底：若后台预取仍在途，立即浮出提示 —— 用户已滑到边界在等，不宜再保持静默
   * （否则尾部是一片空白占位，比转圈更糟）。
   */
  private revealLoadHintOnReachEnd(): void {
    if (this.loadingMore && !this.loadMoreFailed) {
      this.clearLoadingHintTimer();
      this.loadingHintVisible = true;
    }
  }

  private async autoLoadMore(): Promise<void> {
    const myToken: number = this.loadToken;
    while (myToken === this.loadToken && this.hasMore && this.threads.length < 8) {
      const currentPage: number = this.page;
      await this.loadMore(true);
      if (currentPage === this.page) {
        break;
      }
    }
  }

  /**
   * 吧主页预加载：滚动剩余距离 < 阈值时提前静默加载下一页，实现触底无缝续流。
   * 搜索态下改为"接近结果末尾即续扫下一批吧内分页"（批量补扫，不再等触底才挤出一条）。
   * loadingMore / searchFetching 锁 + 偏移节流防重；onReachEnd 保留作兜底。
   */
  /** 「帖子极速开启」当前可见帖子登记（进入视野顺序，最新在前；停歇预取取前 3） */
  private visibleTids: string[] = [];
  /** 手指按下 y（按下让滑动暂停；单列 Scroll 分支无卡片几何，按登记顺序兜底） */
  private listPausePressY: number = -1;
  private listSwipeTimer: number = -1;
  private listPrefetchTimer: number = -1;

  // ===== 单列档窗口化挂载（2026-09-28「越滑越卡」治理）=====
  // 量化结论：单列 Scroll+Column+ForEach 全量渲染下，翻页追加的主线程停顿随总卡数线性增长
  // （+13 条 488ms → +19 条 1616ms）。窗口化后挂载树恒为「可见区 ± 缓冲」，append 只改占位高度。
  // 2026-09-30 与首页 HomeTab 同口径收敛（首页实测：一次推进 = 15~20ms 整列重排固定代价
  // + ~4.5ms/张组件构建，与模糊/图片无关）：
  //   ① 推进从「紧贴挂载边界」改为「贴边后一次性扩到 ±SLOT_EXTEND 给足余量」——
  //      否则缓冲越小推进越频繁，会退化成每帧一次整页重建；
  //   ② 新增 SLOT_KEEP 卸载滞后：可见区外超过该张数才降级回占位，回滑路径上刚看过的卡零重建。
  /** 挂载缓冲：可见区上下各「必须挂载」的张数（视口距窗口边界小于该值即视为贴边） */
  private readonly SLOT_BUFFER: number = 4;
  /** 扩展目标：贴边后一次性扩到「可见区 ± SLOT_EXTEND」，单帧新建量 = SLOT_EXTEND − SLOT_BUFFER */
  private readonly SLOT_EXTEND: number = 9;
  /** 卸载滞后：可见区外超过该张数才降级回等高占位（一次收缩最多卸载 SLOT_KEEP − SLOT_EXTEND 张） */
  private readonly SLOT_KEEP: number = 15;
  /** 首屏初始挂载数 */
  private readonly SLOT_INITIAL: number = 12;
  /** 窗口起始/结束索引（含端点）。@State：仅窗口移动时触发重建，重建范围被 key 稳定性摊薄 */
  @State private slotStart: number = 0;
  @State private slotEnd: number = 11;
  /** 实测卡高表（vp，键=tid）：卡片可见期由 onAreaChange 采集（首测锁定），出窗后供占位复用 */
  private slotHeightMap: Map<string, number> = new Map<string, number>();
  /** 容量上限（提高到 1200：长距离下滑后回滑仍能命中实测值，避免退化到估算） */
  private readonly SLOT_HEIGHT_CAP: number = 1200;
  /** 未实测卡的估算高（vp）：单一 EMA 均值兜底（真机实测偏差可达 ±190vp，故仅作最后兜底） */
  private slotAvgH: number = 340;
  /**
   * 内容特征桶均值（滚动中自校准）：键 = 图片数_标题行数_摘要行数。
   * 未实测卡优先取「同特征卡」的实测均值 —— 首页实测证明占位高与真卡高不一致时
   * （单一均值估算偏差 80~120vp）回落替换真卡会引发高度重排，把视口内容推走（观感=抽搐/露白）。
   */
  private slotBucketH: Map<string, number> = new Map<string, number>();

  private slotList(): ThreadItem[] {
    return this.normalThreads();
  }

  private slotHeightOf(item: ThreadItem): number {
    const h: number | undefined = this.slotHeightMap.get(item.tid);
    return h !== undefined ? h : this.slotEstimateHeight(item);
  }

  /** 未实测卡估算：优先同特征桶实测均值，缺样本时用结构公式打底（自校准，无需人工调参） */
  private slotEstimateHeight(item: ThreadItem): number {
    const learned: number | undefined = this.slotBucketH.get(this.slotBucketKey(item));
    if (learned !== undefined) {
      return learned;
    }
    return this.slotFormulaHeight(item);
  }

  /** 特征键：图片数_标题行数_摘要行数（同键卡的实际高度高度一致，故桶均值可作占位高） */
  private slotBucketKey(item: ThreadItem): string {
    const ic: number = item.images !== undefined ? Math.min(item.images.length, 9) : 0;
    const scale: number = this.fontScale > 0 ? this.fontScale : 1.0;
    const lineW: number = this.slotLineWidth();
    const tl: number = this.slotTextLines(item.title, 17 * scale, lineW, 2);
    const al: number = item.abstract.length > 0 ? this.slotTextLines(item.abstract, 14 * scale, lineW, 4) : 0;
    return `${ic}_${tl}_${al}`;
  }

  /** 文本可用宽 = 视口宽 − 容器左右留白(12×2) − 卡内左右内距(16×2) */
  private slotLineWidth(): number {
    const w: number = this.viewportW > 0 ? this.viewportW : 360;
    return Math.max(120, w - 56);
  }

  /** 文本行数估算：CJK 按 1 字宽、其余约 0.55 字宽；clamp 到 maxLines */
  private slotTextLines(text: string, fontSize: number, availW: number, maxLines: number): number {
    if (text.length === 0) {
      return 1;
    }
    let units: number = 0;
    for (let i: number = 0; i < text.length; i++) {
      units += text.charCodeAt(i) > 0x2E80 ? 1 : 0.55;
    }
    const lines: number = Math.ceil((units * fontSize) / Math.max(1, availW));
    return Math.max(1, Math.min(maxLines, lines));
  }

  /** 图片区高度（单列档，含 top 10）：1 张 220；2/4 张两列 140；其余三列 100（行间 8vp） */
  private slotGalleryHeight(count: number): number {
    if (count <= 0) {
      return 0;
    }
    if (count === 1) {
      return 10 + 220;
    }
    const twoCol: boolean = count === 2 || count === 4;
    const cell: number = twoCol ? 140 : 100;
    const rows: number = Math.ceil(count / (twoCol ? 2 : 3));
    return 10 + rows * cell + (rows - 1) * 8;
  }

  /** 结构公式（桶无样本时的兜底）：逐项复刻 ThreadCard 的真实组成 */
  private slotFormulaHeight(item: ThreadItem): number {
    const scale: number = this.fontScale > 0 ? this.fontScale : 1.0;
    const lineW: number = this.slotLineWidth();
    let h: number = 16 + 40;
    const tl: number = this.slotTextLines(item.title, 17 * scale, lineW, 2);
    h += 8 + tl * 17 * scale * 1.45;
    if (item.abstract.length > 0) {
      const al: number = this.slotTextLines(item.abstract, 14 * scale, lineW, 4);
      h += 6 + al * 14 * scale * 1.5;
    }
    const ic: number = item.images !== undefined ? Math.min(item.images.length, 9) : 0;
    h += this.slotGalleryHeight(ic);
    if (item.forumName.length > 0) {
      h += 10 + 20;
    }
    h += 12 + 36 + 14;
    return h;
  }

  /** 高度表版本号：任何卡高变化即递增，用于前缀和缓存失效 */
  private slotHeightVer: number = 0;
  private slotPreCache: number[] = [0];
  private slotPreSrc: ThreadItem[] | undefined = undefined;
  private slotPreVer: number = -1;

  /** 前缀和：pre[i] = 第 i 张卡的顶部 y（pre[0]=0）。带缓存：仅在列表引用或高度表变化时重算 */
  private slotPrefixSums(): number[] {
    const list: ThreadItem[] = this.slotList();
    if (this.slotPreSrc === list && this.slotPreVer === this.slotHeightVer) {
      return this.slotPreCache;
    }
    const pre: number[] = new Array<number>(list.length + 1);
    pre[0] = 0;
    for (let i = 0; i < list.length; i++) {
      pre[i + 1] = pre[i] + this.slotHeightOf(list[i]);
    }
    this.slotPreCache = pre;
    this.slotPreSrc = list;
    this.slotPreVer = this.slotHeightVer;
    return pre;
  }

  /** 卡高采集（持续更新）。仅窗口内卡挂回调 → 观察者 O(窗口)。
   *  不锁首测：图片失败降级 ↔ 自愈会改变卡高，占位必须跟上，否则回滑时错位。
   *  同时把实测值回灌「同特征桶」（EMA），供未实测卡做占位高。 */
  private slotRecordHeight(item: ThreadItem, h: number): void {
    if (h <= 0 || h > 2000) {
      return;
    }
    const tid: string = item.tid;
    if (this.slotHeightMap.get(tid) !== h) {
      this.slotHeightMap.set(tid, h);
      this.slotHeightVer++;
      this.slotAvgH = this.slotAvgH * 0.9 + h * 0.1;
      const key: string = this.slotBucketKey(item);
      const bk: number | undefined = this.slotBucketH.get(key);
      this.slotBucketH.set(key, bk === undefined ? h : bk * 0.7 + h * 0.3);
    }
    if (this.slotHeightMap.size > this.SLOT_HEIGHT_CAP) {
      let oldest: string | undefined = undefined;
      for (const k of this.slotHeightMap.keys()) {
        oldest = k;
        break;
      }
      if (oldest !== undefined) {
        this.slotHeightMap.delete(oldest);
      }
    }
  }

  /** 滚动中推进窗口（onScroll 每帧调用）：
   *  v2（2026-09-28 真机回归修正）：①可见区贴住窗口边缘才滑动（滞回）——
   *  窗口每动一次都是一次页面级重渲染，甩滑中逐卡滑动会变成重建风暴（真机实测更卡）；
   *  ②前缀和走缓存，滚动帧零 O(N) 计算。
   *  v3（2026-09-30 与首页同口径）：贴边后一次扩到 ±SLOT_EXTEND 给足余量（否则退化成每帧推进），
   *  越过 ±SLOT_KEEP 才收缩（卸载滞后，回滑路径上刚看过的卡零重建）。 */
  private slotUpdateWindow(atY: number): void {
    const list: ThreadItem[] = this.slotList();
    const n: number = list.length;
    if (n === 0 || this.viewportH <= 0) {
      return;
    }
    const pre: number[] = this.slotPrefixSums();
    const bottom: number = atY + this.viewportH;
    let vs: number = 0;
    while (vs < n - 1 && pre[vs + 1] <= atY) {
      vs++;
    }
    let ve: number = vs;
    while (ve < n - 1 && pre[ve + 1] <= bottom) {
      ve++;
    }
    // 必须挂载边界（可见区 ± SLOT_BUFFER）／扩展目标／保留边界
    const mountS: number = Math.max(0, vs - this.SLOT_BUFFER);
    const mountE: number = Math.min(n - 1, ve + this.SLOT_BUFFER);
    const extS: number = Math.max(0, vs - this.SLOT_EXTEND);
    const extE: number = Math.min(n - 1, ve + this.SLOT_EXTEND);
    const keepS: number = Math.max(0, vs - this.SLOT_KEEP);
    const keepE: number = Math.min(n - 1, ve + this.SLOT_KEEP);
    let ns: number = this.slotStart;
    let ne: number = this.slotEnd;
    // ① 贴住挂载边界 → 一次扩到扩展目标
    if (ns > mountS) {
      ns = extS;
    }
    if (ne < mountE) {
      ne = extE;
    }
    // ② 卸载滞后：越过保留带才收缩
    if (ns < keepS) {
      ns = extS;
    }
    if (ne > keepE) {
      ne = extE;
    }
    // ③ 覆盖兜底：任何情况下视口都不得落到占位区
    if (ns > mountS) {
      ns = mountS;
    }
    if (ne < mountE) {
      ne = mountE;
    }
    if (ns !== this.slotStart || ne !== this.slotEnd) {
      // P0-2 归因打点：窗口真正推进 = 一次页面级重渲染（只在实际推进分支计数）
      PerfTrace.mark('winSlide');
      this.slotStart = ns;
      this.slotEnd = ne;
    }
  }

  /** 窗口复位（切排序 / 回顶 / 刷新换血）：回首屏挂载量；卡高表保留（同吧同卡高度可复用） */
  private slotReset(): void {
    this.slotStart = 0;
    this.slotEnd = this.SLOT_INITIAL - 1;
  }

  /** 卡片进入/离开视野登记（WaterFlow 与单列 Scroll 两分支的 ThreadCard 均挂） */
  private onCardListVisible(tid: string, isVisible: boolean): void {
    const idx: number = this.visibleTids.indexOf(tid);
    if (isVisible) {
      if (idx >= 0) {
        this.visibleTids.splice(idx, 1);
      }
      this.visibleTids.unshift(tid);
    } else if (idx >= 0) {
      this.visibleTids.splice(idx, 1);
    }
  }

  /** 记录吧头起始高度与手指最近一次移动的方向 */
  private onListTouchRecord(event: TouchEvent): void {
    if (event.type === TouchType.Down && event.touches.length > 0) {
      const touch: TouchObject = event.touches[0];
      this.listPausePressY = touch.y;
      this.forumDragStartOffset = PrefetchGate.absoluteY(this.listScroller);
      this.forumDragFingerY = touch.windowY;
      this.forumDragDirection = 0;
      this.forumReleaseSpeed = 0;
      this.forumHeaderSnapApplied = false;
    } else if (event.type === TouchType.Move && event.touches.length === 1) {
      const fingerY: number = event.touches[0].windowY;
      const delta: number = this.forumDragFingerY - fingerY;
      if (Math.abs(delta) >= FORUM_HEADER_SNAP_TOLERANCE) {
        this.forumDragDirection = Math.sign(delta);
        this.forumDragFingerY = fingerY;
      }
    }
  }

  private onListScrollStart(): void {
    if (this.listSwipeTimer >= 0) {
      clearTimeout(this.listSwipeTimer);
      this.listSwipeTimer = -1;
    }
    // S1-b 缺口修复（2026-09-29）：服务层 IScrollBusy 让路只由 HomeTab 上报过 —— 吧主页
    // 从未调 notifyFeedScrolling，导致「帖子极速开启」的滑动让路在吧主页完全失效
    // （服务层 feedScrollActive 恒 false、lastFeedScrollAt 过期 → 预取照发）。
    TiebaService.getInstance().notifyFeedScrolling(true);
  }

  /** 滑动停歇 → 300ms 防抖 → 可见登记表前 3 个预取（开关关闭时服务层入口短路） */
  private onListScrollStopPrefetch(): void {
    TiebaService.getInstance().notifyFeedScrolling(false);
    if (this.listSwipeTimer >= 0) {
      clearTimeout(this.listSwipeTimer);
    }
    this.listSwipeTimer = setTimeout(() => {
      this.listSwipeTimer = -1;
      // 方案二（2026-09-28 停歇预取降档）：量化发现每次停歇预取 3 帖 = [TD] 解码 400-700ms×3
      // + 一串 [ENRICH] profile 网络回调，与用户继续滑动抢主线程，深层表现为约每 10s 一次
      // 150-320ms 停顿。列表超过 100 条后降为只预取最近 1 帖（浅层维持 3 不变，极速开启语义不变）。
      const cap: number = this.threads.length > 100 ? 1 : 3;
      const picks: ThreadItem[] = [];
      for (const tid of this.visibleTids) {
        const hit: ThreadItem | undefined = this.threads.find((t: ThreadItem): boolean => t.tid === tid);
        if (hit !== undefined) {
          picks.push(hit);
          if (picks.length >= cap) {
            break;
          }
        }
      }
      TiebaService.getInstance().prefetchFeedTopThreads(picks);
    }, 300);
  }

  /** 「帖子极速开启」列表预取调度：800ms 防抖，取列表前 3 卡（数据同步收口点调用，去重后近零开销） */
  private scheduleListPrefetch(): void {
    if (this.listPrefetchTimer >= 0) {
      clearTimeout(this.listPrefetchTimer);
    }
    this.listPrefetchTimer = setTimeout(() => {
      this.listPrefetchTimer = -1;
      TiebaService.getInstance().prefetchFeedTopThreads(this.waterFlowThreads());
    }, 800);
  }

  private onListScroll(_x: number, _y: number): void {
    // P0-2 归因打点：只记时间戳，供 FSTAT 判定「本窗口是否在滚动」
    PerfTrace.noteScroll();
    const atY: number = PrefetchGate.absoluteY(this.listScroller);
    this.lastScrollY = atY;
    const headerOffset: number = this.searchMode ? 0 : Math.max(0, Math.min(atY, this.forumHeaderBodyH));
    if (headerOffset !== this.forumHeaderOffset) {
      this.forumHeaderOffset = headerOffset;
    }
    // 沉浸式阅读补全（2026-09-29）：先于搜索/加载的 early-return，任何滚动都参与判定
    this.listImmersiveScroll(atY);
    if (this.searchMode) {
      // 搜索态与列表态解耦：不依赖吧内列表的 loadState（列表可能尚未加载完就进了搜索），
      // 且按模式分派（服务端翻页 / 本地续扫），接近结果末尾即提前取下一批
      if (this.prefetchGate.should(atY, this.searchContentH(), this.viewportH)) {
        this.searchNextBatch();
      }
      return;
    }
    if (this.loadState !== LoadState.Success) {
      return;
    }
    // 窗口化挂载（仅回退路径）：每帧按 offset 推进可见窗口（状态未变时零重建）；
    // 单列档虚拟化后 WaterFlow 自管可见区，不再需要外部推进
    if (!THREAD_LIST_SINGLE_WATERFLOW) {
      this.slotUpdateWindow(atY);
    }
    if (this.loadingMore || !this.hasMore) {
      return;
    }
    if (this.prefetchGate.should(atY, this.listContentH(), this.viewportH)) {
      this.loadMore(true);
    }
  }

  private onForumScrollIndex(last: number): void {
    if (this.loadState !== LoadState.Success || !this.hasMore || last <= 0) {
      return;
    }
    // 吧头占索引 0，帖子从 1 起。按实际可见项补足卡高估算在短卡列表里的误差。
    const lastPost: number = this.listDataSource.data.length;
    if (last >= lastPost) {
      if (!this.loadingMore && !this.loadMoreFailed) {
        this.loadMore();
      }
      this.revealLoadHintOnReachEnd();
    } else if (last >= lastPost - 8 * this.threadColumns()) {
      this.loadMore(true);
    }
  }

  private settleForumHeader(fromDrag: boolean): void {
    if (this.forumHeaderSnapApplied || this.searchMode || this.forumPullOffset > 0 || this.refreshing) {
      return;
    }
    const offset: number = PrefetchGate.absoluteY(this.listScroller);
    const height: number = this.forumHeaderBodyH;
    if (offset <= 0 || offset >= height - FORUM_HEADER_SNAP_TOLERANCE) {
      return;
    }
    const midpoint: number = height / 2;
    let collapse: boolean = offset >= midpoint;
    if (fromDrag) {
      // 先看这次拖动有没有越过半程，未越过时再采用快速离手的方向。
      const startedExpanded: boolean = this.forumDragStartOffset < midpoint;
      const crossedMidpoint: boolean = startedExpanded ? offset >= midpoint : offset <= midpoint;
      if (crossedMidpoint) {
        collapse = startedExpanded;
      } else if (this.forumReleaseSpeed >= FORUM_HEADER_FLICK_SPEED) {
        collapse = this.forumDragDirection !== 0 ? this.forumDragDirection > 0 : offset > this.forumDragStartOffset;
      }
    }
    const target: number = collapse && !this.listScroller.isAtEnd() ? height : 0;
    // 吸附会结束当前惯性，同一次手势只处理一次。
    this.forumHeaderSnapApplied = true;
    this.listScroller.scrollTo({ xOffset: 0, yOffset: target, animation: { duration: 180, curve: Curve.EaseOut } });
  }

  // ===== 「沉浸式阅读补全」交互（2026-09-29，设置 → 个性化 / AppStorage `immersiveReadExtra`）=====

  /**
   * 滚动 → 沉浸显隐判定。规则与 ThreadDetail 逐项同源（24 藏 / 12 露不对称 + 置顶 8 恒显示 + 跳变 240 丢弃）。
   * 搜索态不参与（搜索框在顶栏内须恒可见）：强制恢复显示。
   */
  private listImmersiveScroll(atY: number): void {
    if (!this.floatingPageBars || !this.immersiveReadExtra || this.searchMode) {
      if (this.immersiveHidden) {
        this.setListImmersiveHidden(false);
      }
      return;
    }
    if (!this.isForumHeaderCollapsed()) {
      this.resetListImmersive();
      return;
    }
    const act = this.listImmersiveSensor.feed(atY);
    if (act === 'hide') {
      this.setListImmersiveHidden(true);
    } else if (act === 'show' || act === 'reset') {
      this.setListImmersiveHidden(false);
    }
  }

  /** 翻转沉浸态（本地 @State，值变化才写）+ 同步判定器 */
  private setListImmersiveHidden(hidden: boolean): void {
    if (this.immersiveHidden === hidden) {
      return;
    }
    this.immersiveHidden = hidden;
    this.listImmersiveSensor.setHidden(hidden);
  }

  /** 复位沉浸判定（进出搜索态等）：清基线 + 恢复显示 */
  private resetListImmersive(): void {
    this.listImmersiveSensor.resetBaseline();
    if (this.immersiveHidden) {
      this.listImmersiveSensor.setHidden(false);
      this.immersiveHidden = false;
    }
  }

  /** 设置开关变化（@Watch）：关掉开关立即恢复显示 */
  private onListImmersiveExtraChanged(): void {
    if (!this.immersiveReadExtra) {
      this.resetListImmersive();
    }
  }

  /** 顶栏隐藏位移（vp，向上）：= 槽位标题高 98 × 0.6 ≈ −59（同「收回」口径，其余交给 opacity 淡出） */
  private listTopSink(): number {
    return -(THREAD_LIST_TITLE_BAR_HEIGHT * IMMERSIVE_EXTRA_FLY_SCALE);
  }

  /** 底部组合隐藏位移（vp，向下）：= (排序栏高 56 + 底距 30) × 0.6 ≈ 52 */
  private listBottomSink(): number {
    return 56 * IMMERSIVE_EXTRA_FLY_SCALE;
  }

  /** 显隐动画参数（藏 / 唤不对称）：取值以目标态为准 */
  private listImmersiveAnim(): AnimateParam {
    if (this.immersiveHidden) {
      return { duration: IMMERSIVE_EXTRA_HIDE_MS, curve: Curve.EaseIn };
    }
    return {
      duration: IMMERSIVE_EXTRA_SHOW_MS,
      curve: curves.springMotion(IMMERSIVE_EXTRA_SPRING_RESPONSE, IMMERSIVE_EXTRA_SPRING_DAMPING)
    };
  }

  /** 内容尺寸变化：记录内容高；搜索态下内容变化即重判自动续载（结果不满一屏时无法滚动） */
  private onContentAreaChange(_old: Area, n: Area): void {
    const h: number = n.height as number;
    if (h > 0) {
      this.contentH = h;
    }
    // 真机自证：单列档几何来源（每会话一条，onAreaChange 是高频回调不重复打）
    if (!this.contentSrcNoted && this.contentH > 0 && !this.searchMode && this.threadColumns() <= 1 && this.viewportH > 0) {
      this.contentSrcNoted = true;
      this.prefetchGate.noteGeometry('measured(single-column)', this.contentH, this.viewportH);
    }
    if (this.searchMode) {
      this.maybeAutoContinueSearch();
    }
  }

  /**
   * 待用内容总高（vp）：单列档（Scroll + Column 全量渲染）用 onAreaChange 实测值；
   * 多列档是 WaterFlow 虚拟容器 —— **自身高恒等于视口高**，不存在内容总高的读取接口，
   * 故按「顶栏让位 + 吧头块 + 每列条数 × 卡高估算 + 底部让位」折算。
   */
  private listContentH(): number {
    // 单列档已虚拟化（WaterFlow 无内容总高实测接口）→ 与多列档同走折算（宁早取不漏取）。
    // 搜索态仍走实测值（Scroll 分支的 onContentAreaChange），不经本方法。
    return this.estimatedColumnContentH();
  }

  /** 搜索态内容总高（vp）：搜索结果一律单列渲染，沿用实测值即可 */
  private searchContentH(): number {
    return this.contentH;
  }

  /**
   * 多列档内容总高折算（vp）：只求相对准以定位预取阈值（见 docs/帖子预加载.md §8 维护须知），
   * 不做像素级承诺。取值刻意略偏小：折算偏小 → 剩余距离偏小 → 触发更早，宁可早取不漏取。
   */
  private estimatedColumnContentH(): number {
    const cols: number = Math.max(1, this.threadColumns());
    // 条数取合并数据源（置顶+普通，单列/多列同源）；间距/边距按旧单列口径（6 / 12），
    // 另加吧头实测高；多列档口径完全不动。
    const single: boolean = cols <= 1;
    const count: number = this.listDataSource.data.length;
    const gap: number = single ? 6 : Spacing.md;
    const side: number = single ? 12 : Spacing.lg;
    // 可用总宽 = 窗口宽 − 左右外边距 − 列间距（折算口径统一收口在 PrefetchGate，卡高估算也在那里）
    const availW: number = Math.max(1, this.pageWidth) - side * 2 - gap * (cols - 1);
    const total: number = PrefetchGate.estimateWaterfallContentH(count, cols, availW, gap)
      + (single ? this.headerBlockH : 0);
    // 真机自证：折算参数一次性打全（若真机预取时机偏早/偏晚，照这行日志校准权重即可）
    if (!this.contentSrcNoted && this.viewportH > 0 && count > 0) {
      this.contentSrcNoted = true;
      this.prefetchGate.noteGeometry(`estimated(${cols}col)`, total, this.viewportH);
    }
    return total;
  }

  /** 视口尺寸变化：记录视口高 / 宽（宽供旧页快照 region 裁剪用）；搜索态下同时补一次自动续载判定 */
  private onViewportAreaChange(_old: Area, n: Area): void {
    this.viewportH = n.height as number;
    this.viewportW = n.width as number;
    // 单列档虚拟化（2026-09-23）：列数翻档（旋转/折叠/小窗拖拽）会改变 WaterFlow 分段结构
    //（单列四段 / 多列两段），这里补一次幂等重算（lastSectionKey 去重，配置未变零开销）；
    // onListFormAreaChange 已有同类兜底，双保险防「子节点数 == Σ itemsCount」失配。
    this.syncSections();
    if (this.searchMode) {
      this.maybeAutoContinueSearch();
    }
  }

  /**
   * 本吧搜索态进出转场（吧头区 / 列表区 / 结果区 / 顶栏共用）：
   * 出现时自 (offsetX, offsetY) 处滑入 + 淡入，消失时反向滑出 + 淡出。
   * 用不对称时长——出现 240ms FastOutSlowIn（收尾稳），消失 180ms EaseIn（起步快）——
   * 避免两态直切造成的生硬割裂；offsetY 取负表现为「向上轻收/自上方落下」，取正为「自下方浮起/下沉」。
   */
  private searchSwap(offsetX: number, offsetY: number): TransitionEffect {
    const off: TranslateOptions = { x: offsetX, y: offsetY };
    const appear: TransitionEffect = TransitionEffect.opacity(0)
      .combine(TransitionEffect.translate(off))
      .animation({ duration: 240, curve: Curve.FastOutSlowIn });
    const disappear: TransitionEffect = TransitionEffect.opacity(0)
      .combine(TransitionEffect.translate(off))
      .animation({ duration: 180, curve: Curve.EaseIn });
    return TransitionEffect.asymmetric(appear, disappear);
  }

  /**
   * 「更多」操作面板控制器（系统 CustomDialog + API 26 沉浸光感）。
   * 几何与全站其余弹窗**统一口径**（用户 2026-09-13 要求「跟首页置顶弹窗一个高度位置」）：
   * 宽度 dialogCardWidth()（带上限、不随平板屏宽拉伸）、圆角 32vp、
   * 底部锚点 Bottom + dy **-110**（原 -30 是改造前自绘浮层的悬浮基线，现与收藏页 / 进吧页
   * 置顶弹窗对齐；手机档同样生效）、遮罩 #06000000；卡内文案 / 字号 / 按钮尺寸全部原样保留。
   * 玻璃层交给 options.systemMaterial（ImmMaterial.dialog()）—— 材质会接管容器的背景色 /
   * 背景模糊 / 边框 / 阴影，故卡内不再自绘那四项。
   * ⚠️ customStyle 必须为 false —— customStyle=true 时弹窗背景强制透明、圆角归 0 且材质不生效。
   */
  private moreSheetController: CustomDialogController = new CustomDialogController({
    builder: ForumMoreDialogCard({
      isDark: $isDark,
      fontScale: $fontScale,
      forumName: $forumName,
      liked: $moreSheetLiked,
      onShare: () => { this.closeMoreSheet(); this.shareForum(); },
      onToggleFollow: () => { this.closeMoreSheet(); this.handleForumFollow(); },
      onDismiss: () => { this.closeMoreSheet(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -110 },
    maskColor: '#06000000',
    cornerRadius: 32,
    // 弹窗宽度：Dimension 不接受 'calc(100% - 48vp)' 字符串，故按屏幕宽换算成数值 vp
    width: this.dialogCardWidth(),
    customStyle: false,
    systemMaterial: ImmMaterial.dialog(),
    openAnimation: { duration: 220, curve: Curve.EaseOut },
    closeAnimation: { duration: 200, curve: Curve.EaseInOut },
    // 点遮罩 / 返回键统一走 closeMoreSheet（与自绘浮层时期「点蒙层关闭」语义一致）
    onWillDismiss: () => { this.closeMoreSheet(); }
  });

  /**
   * 弹窗卡片宽度（vp）= min(400, 屏幕宽 - 48)。
   * ArkTS 的 Dimension 只接受数值 / 百分比 / 资源，不接受 calc 字符串，故换算成数值。
   * **上限 400**（系统弹窗默认宽度上限）：平板 / 折叠展开下「屏幕宽 - 48」可达 900+vp、
   * 弹窗会被拉成通栏（用户真机反馈「弹窗不要拉伸」），故在此显式封顶；
   * 手机档（360 - 48 = 312 < 400）不受影响，逐像素保持。
   */
  private dialogCardWidth(): number {
    const info: display.Display = display.getDefaultDisplaySync();
    const widthVp: number = info.width / info.densityPixels;
    return Math.max(200, Math.min(THREAD_LIST_DIALOG_MAX_WIDTH, widthVp - 48));
  }

  /** showMoreSheet 变化即驱动系统弹窗 open/close（既有 `this.showMoreSheet = x` 调用点零改动） */
  onShowMoreChanged(): void {
    if (this.showMoreSheet) {
      // 打开瞬间同步展示快照（可空对象 forumInfo 不能直接 @Link 进 @CustomDialog）
      this.moreSheetLiked = this.forumInfo?.isLike === true;
      this.moreSheetController.open();
    } else {
      this.moreSheetController.close();
    }
  }

  /** 关闭「更多」操作面板（唯一出口：卡片内回调 / 点遮罩 / 返回键） */
  private closeMoreSheet(): void {
    this.showMoreSheet = false;
  }

  /**
   * 跳转官方吧主页确认弹窗控制器（系统 CustomDialog，与 moreSheetController 同构）：
   * 底部锚点 + 上移 110、宽 dialogCardWidth()、systemMaterial 沉浸光感、customStyle=false
   * （customStyle=true 时弹窗背景强制透明、圆角归 0 且材质不生效）。
   * onWillDismiss 承接「点遮罩 / 返回键 / 侧滑」→ 与取消钮共用 closeJumpDialog。
   */
  private jumpDialogController: CustomDialogController = new CustomDialogController({
    builder: ForumJumpDialogCard({
      isDark: $isDark,
      fontScale: $fontScale,
      targetUrl: $jumpUrlPreview,
      onConfirm: () => { this.confirmJump(); },
      onDismiss: () => { this.closeJumpDialog(); }
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
    onWillDismiss: () => { this.closeJumpDialog(); }
  });

  /** showJumpDialog 变化即驱动系统弹窗 open/close（openJumpDialog / confirmJump 只写状态） */
  onShowJumpChanged(): void {
    if (this.showJumpDialog) {
      this.jumpDialogController.open();
    } else {
      this.jumpDialogController.close();
    }
  }

  private openJumpDialog(): void {
    if (this.forumName.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '吧信息暂不可用' });
      return;
    }
    // 打开前算好链接预览快照（弹窗内取不到宿主方法 forumWebUrl）
    this.jumpUrlPreview = this.forumWebUrl();
    this.showJumpDialog = true;
  }

  private closeJumpDialog(): void {
    this.showJumpDialog = false;
  }

  /** 官方 App 内吧主页直达链接：wapp 域（官方鸿蒙贴吧声明的 skills 不匹配 tieba.baidu.com） */
  private forumAppUrl(): string {
    return `https://wapp.baidu.com/f?kw=${encodeURIComponent(this.forumName)}`;
  }

  /** 网页版吧主页（兜底用，格式与页内分享功能同源） */
  private forumWebUrl(): string {
    return `https://tieba.baidu.com/f?kw=${encodeURIComponent(this.forumName)}`;
  }

  /** 官方贴吧是否已安装（只判断包是否存在，不读取内部结构字段） */
  private isTiebaInstalled(): boolean {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoSync(TIEBA_OFFICIAL_BUNDLE, bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info !== undefined && info !== null;
    } catch (e) {
      return false;
    }
  }

  /** 隐式拉起（浏览器 / 应用市场网页） */
  private startViewUrl(url: string): void {
    const hostCtx = this.getUIContext().getHostContext();
    if (!hostCtx) {
      return;
    }
    try {
      const ctx: common.UIAbilityContext = hostCtx as common.UIAbilityContext;
      const want: Want = { uri: url, action: 'ohos.want.action.viewData', type: 'text/plain' };
      ctx.startAbility(want).catch(() => {
        this.getUIContext().getPromptAction().showToast({ message: '打开失败，请稍后重试' });
      });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '打开失败，请稍后重试' });
    }
  }

  /** 记录跳转失败原因，便于真机 hilog 定位（不会打扰用户） */
  private logJumpFail(step: string, e: Object): void {
    const err = e as BusinessError;
    console.info(`[跳转官方吧主页] ${step}失败 code=${err?.code ?? ''} msg=${err?.message ?? String(e)}`);
  }

  private copyJumpLink(url: string): void {
    try {
      const sysPasteboard = pasteboard.getSystemPasteboard();
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
      sysPasteboard.setData(pasteData, (err: BusinessError | undefined) => {
        const msg: string = err ? '复制失败，请手动复制' : '无法打开官方贴吧，链接已复制';
        this.getUIContext().getPromptAction().showToast({ message: msg });
      });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败，请手动复制' });
    }
  }

  /**
   * 确认跳转：① 限定官方贴吧 + wapp 吧主页 uri（命中贴吧声明的 skills 时直达吧主页）
   * ② 显式 EntryAbility + uri ③ 官方入口 Want / 显式入口名（进 App 首页）
   * ④ 已安装回落浏览器网页版，未安装引导去应用市场（四级链与 ThreadDetail.confirmJump 同源）
   */
  private async confirmJump(): Promise<void> {
    const url: string = this.forumWebUrl();
    const appUrl: string = this.forumAppUrl();
    this.showJumpDialog = false;
    const hostCtx = this.getUIContext().getHostContext();
    if (!hostCtx) {
      this.copyJumpLink(url);
      return;
    }
    const ctx: common.UIAbilityContext = hostCtx as common.UIAbilityContext;
    // ① 限定官方贴吧 + wapp 吧主页链接：命中贴吧声明的 skills，直达 App 内吧主页
    try {
      await ctx.startAbility({
        bundleName: TIEBA_OFFICIAL_BUNDLE,
        uri: appUrl,
        action: 'ohos.want.action.viewData'
      });
      return;
    } catch (e) {
      this.logJumpFail('wapp直达', e);
    }
    // ② 显式指定 EntryAbility 并带 uri：App 在 onNewWant 里解析链接也能落到吧主页
    try {
      await ctx.startAbility({
        bundleName: TIEBA_OFFICIAL_BUNDLE,
        abilityName: 'EntryAbility',
        uri: appUrl,
        action: 'ohos.want.action.viewData'
      });
      return;
    } catch (e) {
      this.logJumpFail('EntryAbility+uri', e);
    }
    // ③ 系统提供的官方入口 Want（打开 App 首页）
    try {
      const launchWant: Want = bundleManager.getLaunchWantForBundleSync(TIEBA_OFFICIAL_BUNDLE);
      await ctx.startAbility(launchWant);
      return;
    } catch (e) {
      this.logJumpFail('launchWant', e);
    }
    // ③ 显式指定常见入口 ability 名兜底（查询三方包信息受权限限制，不能只依赖检测结果）
    const abilityCandidates: string[] = ['EntryAbility', 'MainAbility'];
    for (const abilityName of abilityCandidates) {
      try {
        await ctx.startAbility({ bundleName: TIEBA_OFFICIAL_BUNDLE, abilityName: abilityName });
        return;
      } catch (e) {
        this.logJumpFail(abilityName, e);
      }
    }
    // ④ 全部拉起失败：确认已安装则回落浏览器网页版，否则引导去应用市场
    if (this.isTiebaInstalled()) {
      try {
        await ctx.startAbility({ uri: url, action: 'ohos.want.action.viewData', type: 'text/plain' });
        return;
      } catch (e) {
        this.logJumpFail('浏览器', e);
      }
      this.copyJumpLink(url);
      return;
    }
    this.getUIContext().getPromptAction().showToast({ message: '未安装官方贴吧，正在前往应用市场' });
    this.startViewUrl(TIEBA_MARKET_URL);
  }

  /**
   * 页面主体层（原 build() 根 Stack）：官方槽位路径 / 兜底路径共用。
   * 内层 = 列表 + 悬浮顶栏（槽位路径下改挂 ThreadTitleBar），外层 BottomEnd Stack = 悬浮 FAB
   * （槽位路径下改挂 FabSlotShell）与「更多」面板。
   */
  @Builder
  ThreadListContent() {
    Stack({ alignContent: Alignment.BottomEnd }) {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.searchMode) {
        this.ForumHeaderBackdrop()
      }
      // 排序面板随列表在前景滚动，快划时即使裁切状态尚未同步也会盖住吧信息。
      if (!this.searchMode && !this.isForumHeaderCollapsed()) {
        this.ForumHeaderBuilder()
      }
      // 排序切换过场·旧页层（对应首页 switchTab 的"退场页"）：点击那一刻同步截下的**列表区**内容，
      // 在新页滑入的同时向反侧整屏滑出 —— 两页相接移动，即"两个界面仿佛连着"的来源。
      // 快照已按吧头底边裁过（见 captureExitSnapshot），故这里下移 exitClipTop、高度收到列表区，
      // 与同样只含列表区的新页严格对齐。
      // 收口（SORT_ANIM_SETTLE）后卸载；首次加载、未命中缓存、搜索态或截图失败时该层不存在（自动降级）。
      if (this.exitSnapshot !== null) {
        Image(this.exitSnapshot)
          .width('100%')
          // 高 = 视口高 − 裁剪量（未裁时即整屏高），与快照像素 1:1
          .height(Math.max(0, this.viewportH - this.exitClipTop))
          // 截图与展示区同尺寸，Cover 在此等价 1:1 铺满，不会变形
          .objectFit(ImageFit.Cover)
          // y 落到列表区顶边（水平位移才是过场：百分比相对自身宽 = 屏宽）；
          // + 让位量：列表容器本体已被 Refresh 的 margin 下移到页 90
          .translate({ x: `${this.outOffset}%`, y: this.listTopInset() + this.exitClipTop })
          .hitTestBehavior(HitTestMode.None)
      }
      // 新页（当前内容）：位移与旧页层对向，见 Scroll 链上的 translate
      // 仅多列档走本 WaterFlow；单列档与搜索态走下方 Scroll + Column 全量分支——
      // 单列置顶是「合并卡片」（「置顶」标签 + 多条同在一个 bgCard 容器），WaterFlow 逐格渲染
      // 拼不出该样式，且虚拟容器在沉浸场景有视口剔除风险（docs/floor-vanish-viewport-fix.md，
      // 2026-09-24 实证：跨 section 虚拟化真机整层不渲染，单列档勿再迁入 WaterFlow）。
      if (this.threadColumns() > 1 && !this.searchMode) {
        // ===== WaterFlow 整页滚动（多列档），吧头作为**跨列的首个格子**随内容滚动 =====
        // 与首页（§4.2 决策 12）同一套 WaterFlow；差异仅在分段（WaterFlowSections）：
        //   section 0 = 吧头（crossCount 1）；section 1 = 主体（crossCount 3/4）。
        // 卡片一律取自然高度（不设 onGetItemMainSizeByIndex），置顶卡作为普通格子、不拉伸。
        // 下拉距离延伸吧头底色，排序栏和帖子继续由 Refresh 带动。
        Refresh({ refreshing: this.refreshing, offset: 48, friction: 62, builder: this.ForumRefreshSpace() }) {
        WaterFlow({ scroller: this.listScroller, sections: this.sections }) {
          // 跨列格子（独占整行）：吧头 + 兜底排序栏 —— 与单列档同源，随内容一起滚动
          // （顶栏让位已由 Refresh 的 margin 承担，见容器链）
          FlowItem() {
            Column() {
              Column() {
                Blank().height(this.forumHeaderBodyH || 96)
                this.ForumSortSection()
              }
              .width('100%')
              .onAreaChange((_old: Area, n: Area) => { this.headerBlockH = n.height as number; })
            }
            .width('100%')
          }

          if (this.loadState === LoadState.Success) {
            // ===== 置顶卡 + 普通帖合并数据源（§4.8 决策 13）：单列 / 多列共用同一段 LazyForEach，
            // 仅 sections 的 crossCount 不同（单列 1 / 多列 3-4）。2026-09-24 回退单列虚拟化：
            // 「置顶块 + 普通帖」跨 section 结构在真机上出现整层不渲染（同类问题见
            // docs/floor-vanish-viewport-fix.md 的虚拟容器视口剔除结论），恢复单一数据源口径。
            // 成功态但数据为空（状态切换的瞬态）：补 0 高占位，保证「子节点数 == Σ itemsCount」，
            // 否则 WaterFlow 会因数量不匹配而无法滚动（官方硬约束）
            if (this.listDataSource.data.length === 0) {
              FlowItem() {
                Column().width('100%').height(0)
              }
            }
            LazyForEach(this.listDataSource, (item: ThreadItem) => {
              FlowItem() {
                // 排序过场·帖子位移（§4.8 T-G）：位移**只作用于卡片本身**，`WaterFlow` 容器与吧头完全不动
                // —— 这样吧头不可能被虚拟容器的渲染区裁掉（上一版整页位移 + 吧头反向抵消，真机上吧头会被
                // 裁掉再出现）。换算成 vp 是因为多列下卡片宽仅 1/3~1/4 屏，百分比基准会导致位移不足。
                Column() {
                  if (item.isTop === true && this.selectedSort !== 2) {
                    // 置顶卡 = 瀑布流的普通格子：自然高度、不拉伸，独立卡面（与普通帖同款圆角/底色）
                    Column() {
                      PinnedThreadItem({
                        item: {
                          tid: item.tid, title: item.title, forumName: item.forumName,
                          author: item.author, replyNum: item.replyNum, abstract: item.abstract,
                          firstImage: item.firstImage ?? '', createTime: item.createTime,
                          isTop: item.isTop, isGood: item.isGood,
                        } as ThreadItemData,
                        onTap: (tid: string) => this.openThread(tid)
                      })
                    }
                    .width('100%')
                    .backgroundColor(Theme.bgCard(this.isDark))
                    .borderRadius(FORUM_CARD_RADIUS_BASE * this.cardRadiusScale)
                  } else {
                    ThreadCard({
                      forumScoped: true,
                      item: {
                        tid: item.tid, postId: item.postId ?? '',
                        title: item.title, forumName: item.forumName,
                        forumAvatar: item.forumAvatar ?? '',
                        author: item.author,
                        authorAvatar: item.authorAvatar ?? '',
                        authorId: item.authorId ?? '',
                        replyNum: item.replyNum, likeCount: item.likeCount ?? 0,
                        isLiked: item.isLiked ?? false,
                        abstract: item.abstract,
                        firstImage: item.firstImage ?? '', images: item.images ?? [],
                        imageThumbs: item.imageThumbs ?? [],
                        createTime: item.createTime, isTop: item.isTop, isGood: item.isGood,
                      } as ThreadItemData,
                      onTap: (tid: string) => this.openThread(tid),
                      onLike: (tid: string, postId: string, liked: boolean) => this.handleLike(tid, postId, liked),
                      onShare: (d: ThreadSharePayload) => this.shareThread(d),
                      onComment: (tid: string) => this.openThread(tid),
                      onAvatarTap: (id: string, name: string) => this.openUserProfile(id, name)
                    })
                      .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean) => this.onCardListVisible(item.tid, isVisible))
                  }
                }
                .width('100%')
                .translate({ x: this.sortShiftX() })
              }
            }, (item: ThreadItem) => `${item.tid}_${item.author}_${item.isLiked ? 1 : 0}_${item.likeCount ?? 0}`)
          } else if (this.loadState === LoadState.Loading) {
            // 骨架屏 / 空态 / 错误视图：该 section 的 crossCount = 1，故独占整行；
            // 骨架屏沿用单列档的 skeletonOpacity 轻淡入，避免切到未命中缓存的排序时「闪一下」
            FlowItem() {
              ThreadListSkeleton({ count: 8, columns: this.threadColumns() })
                .width('100%')
                .opacity(this.skeletonOpacity)
            }
          } else if (this.loadState === LoadState.Empty) {
            FlowItem() {
              EmptyView({ message: '该吧暂无帖子', icon: '📭' })
                .height(200)
            }
          } else {
            FlowItem() {
              ErrorView({ message: this.errorMsg, onRetry: () => { this.loadThreads(); } })
                .height(200)
            }
          }
        }
        // 预加载窗口（2026-09-19）：按「列数×2」预建离屏格子（3 列=6、4 列=8），
        // 与首页 WaterFlow 同口径；只改离屏构建窗口，不动几何/材质/滚动行为。
        .cachedCount(Math.max(2, this.threadColumns() * 2))
        .columnsGap(Spacing.md)
        // 单列档保持旧 Scroll+Column 结构的 6vp 卡距（space: 6）；多列档口径不动
        .rowsGap(this.threadColumns() > 1 ? Spacing.md : 6)
        .padding({ bottom: this.contentBottomSpace() })
        // Refresh 已为顶栏让位，WaterFlow 使用其可用高度。
        .height('100%')
        // 排序切换过场（§4.8 T-G）：位移**不挂 `WaterFlow` 整页** —— 挂整页会把吧头一起带走，
        // 而用「吧头反向位移」抵消又会被虚拟容器的渲染区裁掉（真机表现为「吧头被遮挡后再出现」）。
        // 现改为逐张帖子卡片位移（见上面的 `LazyForEach`），容器与吧头保持静止。
        .id(THREAD_SCROLL_SNAPSHOT_ID)
        .scrollBar(BarState.Off)
        .clip(false)
        .expandSafeArea(this.floatingPageBars ? [SafeAreaType.SYSTEM] : [],
          this.floatingPageBars ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [])
        .edgeEffect(EdgeEffect.Spring)
        .onAreaChange((oldValue: Area, newValue: Area) => this.onViewportAreaChange(oldValue, newValue))
        .onScroll((xOffset: number, yOffset: number) => this.onListScroll(xOffset, yOffset))
        .onScrollIndex((_first: number, last: number) => this.onForumScrollIndex(last))
        .onTouch((event: TouchEvent) => this.onListTouchRecord(event))
        .onScrollStart(() => this.onListScrollStart())
        .onWillStopDragging((velocity: number) => { this.forumReleaseSpeed = Math.abs(velocity); })
        .onDidStopDragging(() => this.settleForumHeader(true))
        .onDidStopFling(() => this.settleForumHeader(false))
        .onScrollStop(() => this.onListScrollStopPrefetch())
        .onReachEnd(() => {
          // 用户已滑到边界：后台预取仍在途时立即浮出 loading（空白占位比转圈更糟）
          this.revealLoadHintOnReachEnd();
          if (this.hasMore && !this.loadingMore) {
            this.loadMore();
          }
        })
        // 左右滑切排序·节点兜底挂接：容器自身带的内置滚动手势显然在本节点正常派发
        // （竖向滚动可用），同节点 .gesture 横向 Pan 经方向竞争可与竖滚共存（UserProfile 双页栈同款机制）。
        // 与内层 Stack 的 parallelGesture 多点同触发，由 onSortSwipeEnd 时间戳去重。
        .gesture(
          PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 30 })
            .onActionStart(() => {
              console.info('[TL_SWIPE] waterflow pan start');
              this.lockSwipe();
            })
            .onActionEnd((event: GestureEvent) => {
              this.onSortSwipeEnd(event);
              this.unlockSwipeDelayed();
            })
            .onActionCancel(() => {
              this.unlockSwipeDelayed();
            })
        )
        }
        .width('100%')
        .height(`calc(100% - ${this.listTopInset()}vp)`)
        .margin({ top: this.listTopInset() })
        .clip(!this.immersiveHidden)
        .hitTestBehavior(this.forumHeaderOffset === 0 ? HitTestMode.Transparent : HitTestMode.Default)
        .maxPullDownDistance(FORUM_REFRESH_MAX_PULL)
        .onOffsetChange((offset: number) => { this.forumPullOffset = offset; })
        .onRefreshing(() => { this.handleRefresh(true); })
      } else if (!this.searchMode && THREAD_LIST_SINGLE_WATERFLOW) {
        // ===== 单列档虚拟化（2026-09-30，与首页 HomeTab 同方案；差异点见 THREAD_LIST_SINGLE_WATERFLOW 注释）=====
        // 原 Scroll + Column 全量渲染 + 窗口化挂载在真机 FSTAT 上是「每次窗口推进 = 一帧 30~60ms」，
        // 滑动中表现为周期性抽搐；改虚拟容器后推进帧不复存在（首页同改后 max 11~34ms / d33 0~1）。
        Refresh({ refreshing: this.refreshing, offset: 48, friction: 62, builder: this.ForumRefreshSpace() }) {
          WaterFlow({ scroller: this.listScroller }) {
            // 吧头 + 兜底排序栏：单列无 sections → 作为普通格子占满整行，随内容滚动（与改造前一致）
            FlowItem() {
              Column() {
                Blank().height(this.forumHeaderBodyH || 96)
                this.ForumSortSection()
              }
              .width('100%')
              .onAreaChange((_old: Area, n: Area) => { this.headerBlockH = n.height as number; })
              // 卡距自持（rowsGap=0）：与改造前 Column space:6 的间隙语义逐项一致
              .margin({ bottom: 6 })
            }

            if (this.loadState === LoadState.Success) {
              LazyForEach(this.listDataSource, (item: ThreadItem) => {
                FlowItem() {
                  Column() {
                    if (item.isTop === true && this.selectedSort !== 2) {
                      if (item.tid === this.firstPinnedTid()) {
                        this.PinnedForumGroup(this.pinnedThreads())
                      } else {
                        // 其余置顶项已并入上方合并块：0 高让位（rowsGap=0 故不产生间距）
                        Column().width('100%').height(0)
                      }
                    } else {
                      ThreadCard({
                        forumScoped: true,
                        item: {
                          tid: item.tid, postId: item.postId ?? '',
                          title: item.title, forumName: item.forumName,
                          forumAvatar: item.forumAvatar ?? '',
                          author: item.author,
                          authorAvatar: item.authorAvatar ?? '',
                          authorId: item.authorId ?? '',
                          replyNum: item.replyNum, likeCount: item.likeCount ?? 0,
                          isLiked: item.isLiked ?? false,
                          abstract: item.abstract,
                          firstImage: item.firstImage ?? '', images: item.images ?? [],
                          imageThumbs: item.imageThumbs ?? [],
                          createTime: item.createTime, isTop: item.isTop, isGood: item.isGood,
                        } as ThreadItemData,
                        onTap: (tid: string) => this.openThread(tid),
                        onLike: (tid: string, postId: string, liked: boolean) => this.handleLike(tid, postId, liked),
                        onShare: (d: ThreadSharePayload) => this.shareThread(d),
                        onComment: (tid: string) => this.openThread(tid),
                        onAvatarTap: (id: string, name: string) => this.openUserProfile(id, name)
                      })
                        .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean) => this.onCardListVisible(item.tid, isVisible))
                        .margin({ bottom: 6 })
                    }
                  }
                  .width('100%')
                  .padding({ left: this.cardSideInset(), right: this.cardSideInset() })
                  .translate({ x: this.sortShiftX() })
                }
              }, (item: ThreadItem) => `${item.tid}_${item.author}_${item.isLiked ? 1 : 0}_${item.likeCount ?? 0}`)
            } else if (this.loadState === LoadState.Loading) {
              FlowItem() {
                ThreadListSkeleton({ count: 4, columns: this.threadColumns() })
                  .width('100%')
                  .opacity(this.skeletonOpacity)
              }
            } else if (this.loadState === LoadState.Empty) {
              FlowItem() {
                EmptyView({ message: '该吧暂无帖子', icon: '📭' })
                  .height(200)
              }
            } else {
              FlowItem() {
                ErrorView({ message: this.errorMsg, onRetry: () => { this.loadThreads(); } })
                  .height(200)
              }
            }

            if (this.loadState === LoadState.Success) {
              FlowItem() {
                this.ForumListFooter()
              }
            }
          }
          .columnsTemplate('1fr')
          .cachedCount(3)
          // rowsGap 置 0：卡距由卡片自身 margin.bottom(6) 承担（置顶让位格才不产生间距）
          .rowsGap(0)
          .padding({ bottom: this.contentBottomSpace() })
          // 容器在 Refresh 内 → 用满高（Refresh 已 margin 90 下移）
          .height('100%')
          // 排序过场：位移逐张挂卡片（容器与吧头静止），与多列档同款；快照锚点仍是本容器
          .id(THREAD_SCROLL_SNAPSHOT_ID)
          .scrollBar(BarState.Off)
          .clip(false)
          .expandSafeArea(this.floatingPageBars ? [SafeAreaType.SYSTEM] : [],
          this.floatingPageBars ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [])
          .edgeEffect(EdgeEffect.Spring)
          .onAreaChange((oldValue: Area, newValue: Area) => this.onViewportAreaChange(oldValue, newValue))
          .onScroll((xOffset: number, yOffset: number) => this.onListScroll(xOffset, yOffset))
          .onScrollIndex((_first: number, last: number) => this.onForumScrollIndex(last))
          .onTouch((event: TouchEvent) => this.onListTouchRecord(event))
          .onScrollStart(() => this.onListScrollStart())
          .onWillStopDragging((velocity: number) => { this.forumReleaseSpeed = Math.abs(velocity); })
          .onDidStopDragging(() => this.settleForumHeader(true))
          .onDidStopFling(() => this.settleForumHeader(false))
          .onScrollStop(() => this.onListScrollStopPrefetch())
          .onReachEnd(() => {
            this.revealLoadHintOnReachEnd();
            if (this.hasMore && !this.loadingMore && !this.loadMoreFailed) {
              this.loadMore();
            }
          })
          .gesture(
            PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 30 })
              .onActionStart(() => {
                console.info('[TL_SWIPE] single waterflow pan start');
                this.lockSwipe();
              })
              .onActionEnd((event: GestureEvent) => {
                this.onSortSwipeEnd(event);
                this.unlockSwipeDelayed();
              })
              .onActionCancel(() => {
                this.unlockSwipeDelayed();
              })
          )
        }
        .width('100%')
        .height(`calc(100% - ${this.listTopInset()}vp)`)
        .margin({ top: this.listTopInset() })
        .clip(!this.immersiveHidden)
        .hitTestBehavior(this.forumHeaderOffset === 0 ? HitTestMode.Transparent : HitTestMode.Default)
        .maxPullDownDistance(FORUM_REFRESH_MAX_PULL)
        .onOffsetChange((offset: number) => { this.forumPullOffset = offset; })
        .onRefreshing(() => { this.handleRefresh(true); })
      } else {
      // 下拉刷新（2026-09-22，docs/下拉刷新.md）：单列档与多列档同款（见多列档注释）
      Refresh({ refreshing: this.refreshing, offset: 48, friction: 62,
        builder: this.searchMode ? undefined : this.ForumRefreshSpace() }) {
      Scroll(this.listScroller) {
        Column() {
          // 顶栏让位已由 Refresh 的 margin 承担（见容器链），内容不再重复让位

          // 本吧本地搜索态：隐藏吧头/排序 Tab，仅显示搜索结果
          // 转场：进入搜索向上轻收淡出、退出搜索自上方落下淡入（与下方结果区反向，形成"换场"层次）
          if (!this.searchMode) {
            Column() {
              Blank().height(this.forumHeaderBodyH || 96)
              this.ForumSortSection()
            }
            .width('100%')
            // 回填吧头块实测高（吧头 + 兜底排序栏）：旧页快照的裁剪边界由它推出（见 captureExitSnapshot）。
            // 只在布局变化时回调；用普通字段而非 @State，避免测量本身触发重建
            .onAreaChange((_old: Area, n: Area) => { this.headerBlockH = n.height as number; })
            .transition(this.searchSwap(0, -16))
          }

          // 帖子列表 / 本吧搜索结果：两态交叉转场（结果区自下方浮起，列表区向上轻收）
          if (this.searchMode) {
            Column() {
              this.SearchResultsBuilder()
            }
            .width('100%')
            .transition(this.searchSwap(0, 24))
          } else {
            // 列表区 Stack：内容层与骨架屏层共存，实现交叉淡入淡出
            Stack({ alignContent: Alignment.TopStart }) {
              // 内容层：Success/Empty 挂载，由 fadeInContent 控制淡入（0→1）
              if (this.loadState === LoadState.Empty) {
                EmptyView({ message: '该吧暂无帖子', icon: '📭' })
                  .height(200)
                  .opacity(this.contentOpacity)
              } else if (this.loadState === LoadState.Success) {
            // 统一容器：所有卡片共享同一水平边距，保证完美对齐
            // （2026-09-28 窗口化 v2：子项数恒定（全量列表 × 真卡/占位分支），容器级 space:6
            //   不再随子项数漂移，恢复原写法——占位与真卡等高，间隙语义与改造前逐像素一致）
            Column({ space: 6 }) {
              if (this.pinnedThreads().length > 0) {
                this.PinnedForumGroup(this.pinnedThreads())
              }

              // 普通帖子区域（ThreadCard自带背景和圆角）
              if (this.threadColumns() > 1) {
                // 多列档（§4.8 T-C）：行分组 + 末行补空位
                ForEach(this.threadRows(this.normalThreads()), (row: ThreadItem[], rowIdx: number) => {
                  Row({ space: 6 }) {
                    ForEach(row, (item: ThreadItem) => {
                      Column() {
                        ThreadCard({
                          forumScoped: true,
                          item: {
                            tid: item.tid, postId: item.postId ?? '',
                            title: item.title, forumName: item.forumName,
                            forumAvatar: item.forumAvatar ?? '',
                            author: item.author,
                            authorAvatar: item.authorAvatar ?? '',
                            authorId: item.authorId ?? '',
                            replyNum: item.replyNum, likeCount: item.likeCount ?? 0,
                            isLiked: item.isLiked ?? false,
                            abstract: item.abstract,
                            firstImage: item.firstImage ?? '', images: item.images ?? [],
                            createTime: item.createTime, isTop: item.isTop, isGood: item.isGood,
                          } as ThreadItemData,
                          onTap: (tid: string) => this.openThread(tid),
                          onLike: (tid: string, postId: string, liked: boolean) => this.handleLike(tid, postId, liked),
                          onShare: (d: ThreadSharePayload) => this.shareThread(d),
                          onComment: (tid: string) => this.openThread(tid),
                          onAvatarTap: (id: string, name: string) => this.openUserProfile(id, name)
                        })
                      }
                      .layoutWeight(1)
                    }, (item: ThreadItem) => `${item.tid}_${item.author}_${item.isLiked ? 1 : 0}_${item.likeCount ?? 0}`)
                    ForEach(this.threadBlankSlots(row.length), (slot: number) => {
                      Column().layoutWeight(1)
                    }, (slot: number) => `row_gap_${rowIdx}_${slot}`)
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Top)
                }, (row: ThreadItem[], rowIdx: number) => `row_${rowIdx}_${row[0].tid}`)
              } else {
                // ===== 单列档窗口化挂载 v2（2026-09-28「越滑越卡」治理）=====
                // ForEach 直接遍历全量列表（key 与索引全程稳定，永不移位），每项按窗口分支：
                // 窗口内 = 真卡；窗外 = 等高轻量占位。进出窗口只是单个子项的分支翻转，
                // 不存在「窗口滑动 → 全体 key 移位 → 整窗重建」（v1 的真机掉帧回归根因）。
                // 等价于 LazyForEach 的边缘增量挂载，但避开本页已知的虚拟容器渲染风险。
                // 置顶块始终全量渲染（数量少）；搜索态不走本分支。
                ForEach(this.normalThreads(), (item: ThreadItem, idx: number) => {
                  if (idx >= this.slotStart && idx <= this.slotEnd) {
                    ThreadCard({
                      forumScoped: true,
                      item: {
                        tid: item.tid, postId: item.postId ?? '',
                        title: item.title, forumName: item.forumName,
                        forumAvatar: item.forumAvatar ?? '',
                        author: item.author,
                        authorAvatar: item.authorAvatar ?? '',
                        authorId: item.authorId ?? '',
                        replyNum: item.replyNum, likeCount: item.likeCount ?? 0,
                        isLiked: item.isLiked ?? false,
                        abstract: item.abstract,
                        firstImage: item.firstImage ?? '', images: item.images ?? [],
                        createTime: item.createTime, isTop: item.isTop, isGood: item.isGood,
                      } as ThreadItemData,
                      onTap: (tid: string) => this.openThread(tid),
                      onLike: (tid: string, postId: string, liked: boolean) => this.handleLike(tid, postId, liked),
                      onShare: (d: ThreadSharePayload) => this.shareThread(d),
                      onComment: (tid: string) => this.openThread(tid),
                      onAvatarTap: (id: string, name: string) => this.openUserProfile(id, name)
                    })
                      .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean) => this.onCardListVisible(item.tid, isVisible))
                      // 卡高采集（持续更新）：出窗后占位复用实测值，避免滚动跳动
                      .onAreaChange((_oldA: Area, newA: Area) => {
                        this.slotRecordHeight(item, newA.height as number);
                      })
                  } else {
                    // 窗口外等高占位：实测卡高优先，未实测用 EMA 估算
                    Column()
                      .width('100%')
                      .height(this.slotHeightOf(item))
                  }
                }, (item: ThreadItem) => `${item.tid}_${item.author}_${item.isLiked ? 1 : 0}_${item.likeCount ?? 0}`)
              }

              this.ForumListFooter()
            }
            .width('100%')
            .padding({ left: this.cardSideInset(), right: this.cardSideInset() })
            .opacity(this.contentOpacity)
              }
              // 骨架屏覆盖层：Loading 期间显示，由 fadeInContent 控制淡出（1→0）
              if (this.loadState === LoadState.Loading) {
                ThreadListSkeleton({ count: 4, columns: this.threadColumns() })
                  .width('100%')
                  .opacity(this.skeletonOpacity)
              }
              // 错误层
              if (this.loadState === LoadState.Error) {
                ErrorView({ message: this.errorMsg, onRetry: () => { this.loadThreads(); } }).height(200)
              }
            }
            .width('100%')
            // 排序切换过场·新页位移：只作用于列表区（对应首页 switchTab 的"进场页"：自对侧整屏进入、归位）。
            // 位移挂在这一层而不是 Scroll 上 —— Scroll 里还装着吧头与兜底排序栏，挂在 Scroll 上会让它们一起滑
            // （首页切 Tab 时标题栏与底栏是静止的，故必须把作用域收窄到列表内容）。只做水平位移，垂直位置不变。
            .translate({ x: `${this.inOffset}%` })
            .transition(this.searchSwap(0, -16))
          }
        }
        .width('100%')
        .padding({ bottom: this.contentBottomSpace() })
        .onAreaChange((oldValue: Area, newValue: Area) => this.onContentAreaChange(oldValue, newValue))
      }
      // 旧页快照锚点（`componentSnapshot.getSync` 取 Scroll 矩形，再按 region 裁掉吧头，见 captureExitSnapshot）；
      // 新页位移已下移到「列表区」那一层，故这里不再挂 translate —— 吧头/兜底排序栏由此保持静止
      .id(THREAD_SCROLL_SNAPSHOT_ID)
      .scrollBar(BarState.Off)
      // Scroll 使用 Refresh 的可用高度。
      .height('100%')
      .clip(false)
      .expandSafeArea(this.floatingPageBars ? [SafeAreaType.SYSTEM] : [],
          this.floatingPageBars ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [])
      .edgeEffect(EdgeEffect.Spring)
      .onAreaChange((oldValue: Area, newValue: Area) => this.onViewportAreaChange(oldValue, newValue))
      .onScroll((xOffset: number, yOffset: number) => this.onListScroll(xOffset, yOffset))
      .onTouch((event: TouchEvent) => this.onListTouchRecord(event))
      .onScrollStart(() => this.onListScrollStart())
      .onWillStopDragging((velocity: number) => { this.forumReleaseSpeed = Math.abs(velocity); })
      .onDidStopDragging(() => this.settleForumHeader(true))
      .onDidStopFling(() => this.settleForumHeader(false))
      .onScrollStop(() => this.onListScrollStopPrefetch())
      .onReachEnd(() => {
        // 搜索态：触底兜底再取一批（正常滚动已在接近末尾时提前取）
        if (this.searchMode) {
          this.searchNextBatch();
          return;
        }
        // 用户已滑到边界：后台预取仍在途时立即浮出 loading（空白占位比转圈更糟）
        this.revealLoadHintOnReachEnd();
        if (this.hasMore && !this.loadingMore && !this.loadMoreFailed) {
          this.loadMore();
        }
      })
      // 左右滑切排序·节点兜底挂接（与多列档 WaterFlow 同款）：容器内置滚动手势在本节点
      // 正常派发，同节点 .gesture 横向 Pan 经方向竞争与竖滚共存；多点同触发由时间戳去重。
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 30 })
          .onActionStart(() => {
            console.info('[TL_SWIPE] scroll pan start');
            this.lockSwipe();
          })
          .onActionEnd((event: GestureEvent) => {
            this.onSortSwipeEnd(event);
            this.unlockSwipeDelayed();
          })
          .onActionCancel(() => {
            this.unlockSwipeDelayed();
          })
      )
      }
      .width('100%')
      .height(`calc(100% - ${this.listTopInset()}vp)`)
      .margin({ top: this.listTopInset() })
      .clip(!this.searchMode && !this.immersiveHidden)
      .hitTestBehavior(!this.searchMode && this.forumHeaderOffset === 0 ? HitTestMode.Transparent : HitTestMode.Default)
      .maxPullDownDistance(this.searchMode ? undefined : FORUM_REFRESH_MAX_PULL)
      .onOffsetChange((offset: number) => {
        if (!this.searchMode) {
          this.forumPullOffset = offset;
        }
      })
      .onRefreshing(() => { this.handleRefresh(true); })
      }

      if (!this.searchMode && this.isForumHeaderCollapsed() && !this.immersiveHidden) {
        Column() {
          this.ForumSortSection(true)
        }
        .width('100%')
        .position({ top: this.listTopInset(), left: 0 })
        .zIndex(8)
      }
      if (this.floatingPageBars && !(THREAD_LIST_OFFICIAL_TITLE_BAR && this.materialSupported)) {
        this.ForumTitleBar(false)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea(this.floatingPageBars ? [SafeAreaType.SYSTEM] : [],
          this.floatingPageBars ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [])
    .linearGradientBlur(this.floatingPageBars && this.searchMode ? TopBarFx.blur(this.tbxTick) : 0,
      { fractionStops: [[1.0, 0.0], [1.0, TopBarFx.solid(this.tbxTick)], [0.0, TopBarFx.fade(this.tbxTick)], [0.0, 1.0]],
        direction: GradientDirection.Bottom })
    .overlay(() => { if (this.floatingPageBars && this.searchMode) { TopGlassVeil() } })
    // 左右滑切排序手势（热门 / 最新 / 精选）：挂**列表内容的直接父层 Stack**（HomeTab 推荐流 /
    // UserProfile 双页栈同款层级，真机验证可用；挂更外层 Stack 真机实测不触发）。
    // parallelGesture 与列表竖向滚动并行识别（Horizontal 轴方向竞争不冲突）。
    // onActionStart 起手即锁卡点按：滑动期间抬指仍可能给卡片派发 click（openThread 内 swipeLock 短路），
    // 抬指延时解锁。同名手势还挂在 WaterFlow / Scroll 节点自身兜底（见各容器链尾），
    // 多点同触发由 onSortSwipeEnd 内 350ms 时间戳去重。
    .parallelGesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 30 })
        .onActionStart(() => {
          console.info('[TL_SWIPE] stack pan start');
          this.lockSwipe();
        })
        .onActionEnd((event: GestureEvent) => {
          this.onSortSwipeEnd(event);
          this.unlockSwipeDelayed();
        })
        .onActionCancel(() => {
          this.unlockSwipeDelayed();
        })
    )

    if (!this.searchMode) {
      this.ForumActionButtons()
    }
    }
    .width('100%')
    .height('100%')
    // 根容器实宽 → currentWidth：排序栏槽位壳的 barWidth 只接受数值（Dimension 不收 calc 字符串）
    // 同点追加形态变化挂点（§4.8 T-B）：窗口尺寸变化时回填宽高 + 横竖屏 + 列数标记
    .onAreaChange((_old: Area, n: Area) => {
      this.currentWidth = n.width as number;
      // 窗口实值优先（2026-09-17 小窗 / 分屏适配：自由多窗下 display ≠ 窗口）
      this.onListFormAreaChange(n.width as number, n.height as number);
    })
  }

  build() {
    if (!this.floatingPageBars) {
      FixedPageBars({
        topColor: this.searchMode ? Theme.bg(this.isDark) : this.forumHeaderColor(),
        bottomColor: Theme.bg(this.isDark),
        content: () => { this.FixedForumContent(); }
      })
    } else if (THREAD_LIST_OFFICIAL_TITLE_BAR && this.materialSupported) {
      Navigation() {
        this.ThreadListContent()
      }
      .title({ builder: this.ForumTitleBar(true), height: THREAD_LIST_TITLE_BAR_HEIGHT },
        { barStyle: BarStyle.STACK, backgroundColor: Color.Transparent })
      .mode(NavigationMode.Stack)
      .hideBackButton(true)
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg(this.isDark))
      .clip(false)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    } else {
      this.ThreadListContent()
    }
  }

  @Builder
  FixedForumContent() {
    Column() {
      this.ForumTitleBar(false)
      Column() {
        this.ThreadListContent()
      }
      .width('100%')
      .layoutWeight(1)
      .clip(true)
    }
    .width('100%')
    .height('100%')
  }

  private listTopInset(): number {
    return this.floatingPageBars ? THREAD_LIST_TITLE_BAR_HEIGHT : 0;
  }

  private forumHeaderColor(): string {
    const theme: string = (this.isDark ? this.forumInfo?.darkHeaderColor : this.forumInfo?.headerColor) ?? '';
    return this.forumArtColor || theme || (this.isDark ? '#2C3B49' : '#3D5061');
  }

  private isForumHeaderCollapsed(): boolean {
    return this.forumHeaderBodyH > 0 && this.forumHeaderOffset >= this.forumHeaderBodyH - FORUM_HEADER_SNAP_TOLERANCE;
  }

  private forumHeaderProgress(): number {
    return Math.min(1, this.forumHeaderOffset / (this.forumHeaderBodyH || 96));
  }

  private forumArtHeight(): number {
    return this.listTopInset() + (this.forumHeaderBodyH || 96) + 19;
  }

  private forumHeaderBackdropHeight(): number {
    if (this.isForumHeaderCollapsed()) {
      return this.listTopInset();
    }
    return Math.max(this.listTopInset(), this.forumArtHeight() - this.forumHeaderOffset + this.forumPullOffset);
  }

  @Builder
  ForumRefreshSpace() {
    // 由吧头背景填充下拉区域，加载时由右下角刷新按钮反馈进度。
    Column()
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  ForumHeaderBackdrop() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.forumHeaderArt !== null && !this.isForumHeaderCollapsed()) {
        Image(this.forumHeaderArt)
          .width('100%')
          .height(this.forumArtHeight())
          .objectFit(ImageFit.Cover)
          .position({ top: 0, left: 0 })
          .id('forum_header_art')
        Column()
          .width('100%')
          .height(this.forumArtHeight())
          .linearGradient({ direction: GradientDirection.Bottom, colors: [
            ['#33000000', 0], ['#15000000', 0.35], ['#C0' + this.forumHeaderColor().slice(1), 0.88],
            [this.forumHeaderColor(), 1]
          ] })
          .position({ top: 0, left: 0 })
        if (this.floatingPageBars) {
          Column()
            .width('100%')
            .height(this.listTopInset())
            .backgroundColor(this.forumHeaderColor())
            .opacity(this.forumHeaderProgress())
            .position({ top: 0, left: 0 })
        }
      }
    }
    .width('100%')
    .height(this.forumHeaderBackdropHeight())
    .backgroundColor(this.forumHeaderColor())
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  ForumTitleBar(inSlot: boolean) {
    Row({ space: 5 }) {
      this.ForumNavButton($r('sys.symbol.chevron_left'), this.searchMode ? '退出搜索' : '返回', 'forum_nav_back',
        inSlot, () => {
          if (this.searchMode) {
            this.exitSearch();
          } else {
            this.getUIContext().getRouter().back();
          }
        })
      if (this.searchMode) {
        Row() {
          TextInput({ placeholder: '搜索「' + this.forumName + '」吧帖子', text: this.searchKeyword })
            .id('forum_search_input')
            .layoutWeight(1)
            .height('100%')
            .fontSize(fs(15, this.fontScale))
            .fontColor(Theme.textPrimary(this.isDark))
            .placeholderColor(Theme.textTertiary(this.isDark))
            .backgroundColor(Color.Transparent)
            .padding({ left: 14, right: 14 })
            .defaultFocus(true)
            .onChange((value: string) => { this.onSearchKeywordChange(value); })
        }
        .layoutWeight(1)
        .height(40)
        .borderRadius(Radius.full)
        .backgroundColor(inSlot ? Color.Transparent : Theme.bgCard(this.isDark))
        .systemMaterial(inSlot ? ImmMaterial.seg(true) : ImmMaterial.empty())
      } else {
        if (this.forumHeaderOffset > 0) {
          Row({ space: 5 }) {
            this.ForumAvatar(22, 5)
            Text(this.forumName + '吧')
              .fontSize(fs(16, this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .id('forum_compact_title')
          .constraintSize({ maxWidth: '56%' })
          .opacity(this.forumHeaderProgress())
          .hitTestBehavior(this.isForumHeaderCollapsed() ? HitTestMode.Default : HitTestMode.None)
          .onClick(() => { this.showMoreSheet = true; })
        }
        Blank()
        this.ForumNavButton($r('sys.symbol.magnifyingglass'), '搜索本吧帖子', 'forum_nav_search',
          inSlot, () => { this.openSearch(); })
        this.ForumNavButton($r('sys.symbol.share'), '分享吧', 'forum_nav_share',
          inSlot, () => { this.shareForum(); })
      }
    }
    .width('100%')
    .height(this.floatingPageBars ? THREAD_LIST_TITLE_BAR_HEIGHT : 52)
    .id('forum_title_bar')
    .padding({ left: 11, right: 11, top: this.floatingPageBars ? 44 : 0, bottom: this.floatingPageBars ? 10 : 0 })
    .backgroundColor(this.searchMode
      ? (this.floatingPageBars ? Color.Transparent : Theme.bg(this.isDark))
      : (this.floatingPageBars && !this.isForumHeaderCollapsed() ? Color.Transparent : this.forumHeaderColor()))
    .translate({ y: this.floatingPageBars && this.immersiveHidden ? this.listTopSink() : 0 })
    .opacity(this.floatingPageBars && this.immersiveHidden ? 0 : 1)
    .enabled(!(this.floatingPageBars && this.immersiveHidden))
    .animation(this.listImmersiveAnim())
    .zIndex(10)
  }

  @Builder
  ForumNavButton(icon: Resource, label: string, nodeId: string, inSlot: boolean, action: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([this.searchMode ? $r('sys.color.icon_primary') : Color.White])
    }
    .width(40)
    .height(40)
    .padding(0)
    .backgroundColor(this.floatingPageBars && !inSlot ? '#26FFFFFF' : Color.Transparent)
    .backgroundBlurStyle(this.floatingPageBars && !inSlot ? BlurStyle.Thin : BlurStyle.NONE)
    .systemMaterial(inSlot ? ImmMaterial.seg(false) : ImmMaterial.empty())
    .id(nodeId)
    .accessibilityText(label)
    .onClick(action)
  }

  @Builder
  ForumActionButtons() {
    Column({ space: 12 }) {
      Button({ type: ButtonType.Circle }) {
        if (this.refreshing) {
          LoadingProgress().width(22).height(22).color(Theme.textPrimary(this.isDark))
        } else {
          SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(24).fontColor([Theme.textPrimary(this.isDark)])
        }
      }
      .width(46)
      .height(46)
      .padding(0)
      .backgroundColor(Theme.bgCard(this.isDark))
      .shadow({ radius: 7, color: '#24000000', offsetY: 2 })
      .id('forum_refresh')
      .accessibilityText('刷新帖子')
      .enabled(!this.refreshing && !this.immersiveHidden)
      .onClick(() => { this.handleRefresh(); })

      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(26).fontColor([Color.White])
      }
      .width(46)
      .height(46)
      .padding(0)
      .backgroundColor('#56768F')
      .shadow({ radius: 7, color: '#24000000', offsetY: 2 })
      .id('forum_publish')
      .accessibilityText('发帖')
      .enabled(!this.immersiveHidden)
      .onClick(() => { this.openCompose(); })
    }
    .margin({ right: 12, bottom: this.floatingPageBars ? 48 : 36 })
    .zIndex(20)
    .translate({ y: this.immersiveHidden ? this.listBottomSink() : 0 })
    .opacity(this.immersiveHidden ? 0 : 1)
    .animation(this.listImmersiveAnim())
  }

  private contentBottomSpace(): number {
    return this.searchMode ? 150 : (this.hasMore ? 24 : 112);
  }

  @Builder
  ForumListFooter() {
    Row() {
      if (!this.hasMore) {
        Text('没有更多帖子')
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textTertiary(this.isDark))
      } else if (this.loadingHintVisible) {
        LoadingView({ message: '正在加载更多…' }).height(LIST_FOOTER_SENTINEL_H)
      } else if (this.loadMoreFailed) {
        Button('加载失败，点击重试')
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.brand())
          .backgroundColor(Color.Transparent)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick(() => { this.loadMore(); })
      }
    }
    .width('100%')
    .height(LIST_FOOTER_SENTINEL_H)
    .justifyContent(FlexAlign.Center)
    .id('forum_load_more_footer')
  }

  @Builder
  ForumAvatar(size: number, radius: number) {
    Stack() {
      Text((this.forumInfo?.forumName ?? this.forumName).charAt(0))
        .fontSize(size * 0.4)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .width('100%')
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor('#56768F')
      if (this.forumInfo && this.forumInfo.avatar.length > 0 && !this.failedAvatar) {
        Image(this.forumInfo.avatar)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .onError(() => { this.failedAvatar = true; })
      }
    }
    .width(size)
    .height(size)
    .borderRadius(radius)
    .clip(true)
  }

  @Builder
  ForumHeaderBuilder() {
    Row({ space: 12 }) {
      this.ForumAvatar(64, 13)
      Column({ space: 8 }) {
        Text((this.forumInfo?.forumName ?? this.forumName) + '吧')
          .fontSize(fs(19, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.forumInfo && this.forumInfo.levelupScore > 0 && !this.forumUnfollowed()) {
          Stack({ alignContent: Alignment.Start }) {
            Row().width('100%').height(2).backgroundColor('#66FFFFFF')
            Row().width(this.progressPercent() + '%').height(2).backgroundColor(Color.White)
          }
          .width('100%')
          Row({ space: 5 }) {
            Text('LV' + this.forumInfo.userLevel + ' ' + this.forumInfo.levelName)
              .fontSize(fs(11, this.fontScale))
              .fontColor('#D9FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Blank()
            Text(this.forumInfo.curScore + '/' + this.forumInfo.levelupScore)
              .fontSize(fs(11, this.fontScale))
              .fontColor('#D9FFFFFF')
              .maxLines(1)
          }
          .width('100%')
        }
      }
      .layoutWeight(1)
      .constraintSize({ maxWidth: this.threadColumns() > 1 ? THREAD_LIST_EXP_BAR_MAX_WIDTH : '100%' })
      .alignItems(HorizontalAlign.Start)
      .onClick(() => { this.showMoreSheet = true; })
      if (this.threadColumns() > 1) {
        Blank()
      }

      Button(this.signButtonLabel())
        .id('forum_sign_status')
        .fontSize(fs(13, this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor('#33FFFFFF')
        .height(30)
        .padding({ left: 10, right: 10 })
        .borderRadius(Radius.full)
        .onClick(() => {
          if (this.forumUnfollowed()) {
            this.handleForumFollow();
          } else {
            this.handleSignIn();
          }
        })
    }
    .width('100%')
    .id('forum_header_info')
    .padding({ left: 12, right: 12, top: 12, bottom: 20 })
    // 吧信息在列表外固定绘制，只更新面板遮住的裁切边。
    .position({ top: this.listTopInset(), left: 0 })
    .clipShape(new RectShape({ width: '100%', height: Math.max(0, (this.forumHeaderBodyH || 96) - this.forumHeaderOffset) }))
    .hitTestBehavior(this.forumHeaderOffset > 0 ? HitTestMode.None : HitTestMode.Transparent)
    .onAreaChange((_old: Area, area: Area) => { this.forumHeaderBodyH = area.height as number; })
  }

  @Builder
  ForumSortSection(sticky: boolean = false) {
    Stack({ alignContent: Alignment.Top }) {
      Column().width('100%').height(19)
        .backgroundColor(sticky || this.forumHeaderArt === null || this.isForumHeaderCollapsed()
          ? this.forumHeaderColor() : Color.Transparent)
      Column({ space: 3 }) {
        Column()
          .width(39)
          .height(4)
          .backgroundColor(Theme.divider(this.isDark))
          .borderRadius(3)
          .margin({ top: 7 })

        Row() {
          this.ForumSortTab('精华', 2)
          this.ForumSortTab('热门', 0)
          this.ForumSortTab('最新', 1)
          Blank()
        }
        .width('100%')

        if (this.selectedSort === 1) {
          Row() {
            Text('看帖排序').fontSize(fs(12, this.fontScale)).fontColor(Theme.textTertiary(this.isDark))
            Blank()
            Row() {
              this.LatestSortOption('回复', 0)
              this.LatestSortOption('发布', 1)
            }
            .padding(2)
            .backgroundColor(this.isDark ? '#2D3037' : '#E9EBF0')
            .borderRadius(Radius.full)
          }
          .width('100%')
          .padding({ left: 9, right: 9, top: 1, bottom: 6 })
        }
      }
      .width('100%')
      .backgroundColor(Theme.bg(this.isDark))
      .borderRadius({ topLeft: 19, topRight: 19, bottomLeft: 0, bottomRight: 0 })
    }
    .width('100%')
    .id(sticky ? 'forum_sort_visible' : 'forum_sort_section')
    .zIndex(1)
  }

  @Builder
  ForumSortTab(label: string, sort: number) {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(fs(15, this.fontScale))
        .fontWeight(this.selectedSort === sort ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.isDark))
      Column()
        .width(24)
        .height(3)
        .borderRadius(2)
        .backgroundColor(this.selectedSort === sort ? '#56768F' : Color.Transparent)
    }
    .width(51)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .scale({ x: this.pressedTab === sort ? 0.93 : 1, y: this.pressedTab === sort ? 0.93 : 1 })
    .animation({ duration: 100, curve: Curve.EaseOut })
    .accessibilityText(label)
    .onTouch((event: TouchEvent) => {
      if (sort === 2) {
        this.onGoodButtonTouch(event);
      }
    })
    .gesture(LongPressGesture({ fingers: 1, repeat: false, duration: 350 })
      .onAction(() => { if (sort === 2) { this.openGoodCategories(); } }))
    .onClick(() => {
      this.pulseTab(sort);
      this.selectSort(sort);
    })
  }

  @Builder
  LatestSortOption(label: string, sort: number) {
    Text(label)
      .fontSize(fs(12, this.fontScale))
      .fontColor(this.latestSortMode === sort ? Theme.textPrimary(this.isDark) : Theme.textTertiary(this.isDark))
      .padding({ left: 13, right: 13, top: 5, bottom: 5 })
      .backgroundColor(this.latestSortMode === sort ? Theme.bgCard(this.isDark) : Color.Transparent)
      .borderRadius(Radius.full)
      .onClick(() => { this.applyLatestSort(sort); })
  }

  private progressPercent(): number {
    if (!this.forumInfo || this.forumInfo.levelupScore <= 0) {
      return 0;
    }
    return Math.min(100, Math.round((this.forumInfo.curScore / this.forumInfo.levelupScore) * 100));
  }

  /** 形态变化唯一挂点：回填窗口宽高 + 横竖屏 + 列数标记（**不包任何过渡动画**，
   *  列数模板不可补间，§4.6 H-G）。窗口尺寸未变则直接返回，避免 onAreaChange 高频回调重排。 */
  private onListFormAreaChange(winW?: number, winH?: number): void {
    // 窗口实值优先（2026-09-17 小窗 / 分屏适配：自由多窗下 display ≠ 窗口）；未就绪退 display 首帧口径
    let w: number = winW ?? 0;
    let h: number = winH ?? 0;
    if (w <= 0 || h <= 0) {
      try {
        const d = display.getDefaultDisplaySync();
        w = this.getUIContext().px2vp(d.width);
        h = this.getUIContext().px2vp(d.height);
      } catch (e) {
        // 忽略：窗口未 attach 时取宽会失败
        return;
      }
    }
    if (w <= 0 || h <= 0) {
      return;
    }
    if (w === this.pageWidth && h === this.pageHeight) {
      return;
    }
    this.pageWidth = w;
    this.pageHeight = h;
    this.isLandscape = w > h;
    this.syncCardColumns();
    // 列数变化 → 主体 section 的 crossCount 必须同步（横竖屏切换：竖 3 / 横 4）
    this.syncSections();
  }

  /**
   * 列数：大屏竖屏 3 / 横屏 4（与首页 §4.2 决策 12 同口径，§4.8 T-B）。
   * 形态闸门必须放首行：只按宽度判会让手机横屏（约 780vp ≥ 600）误命中多列（§6.1 D4）。
   */
  /**
   * 「列数调整」档位变化（个性化页写入 → `columnModeTick` 广播）：
   * 回写本地档位（列数函数随新档返回）→ 重发 cardColumns → 重算 section 列数 → 强制回到列表顶部。
   * 默认档（0）与原自动适配逐像素一致，仅「用户显式选择」后才改变列数。
   */
  private onColumnModeTick(): void {
    this.columnMode = readColumnMode();
    this.syncCardColumns();
    this.syncSections();
    try {
      this.listScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    } catch (e) {
    }
  }

  /** 左右留白变化 → 多列主体 section 的 margin 重算（单列容器 padding 为 build 期直读，自动跟随） */
  private onPageMarginChange(): void {
    this.syncSections();
  }

  private releaseForumHeaderArt(): void {
    const bitmap = this.forumHeaderArt;
    this.forumHeaderArt = null;
    this.forumArtColor = '';
    bitmap?.release().catch(() => {});
  }

  private async loadForumHeaderArt(url: string, color: string, epoch: number): Promise<void> {
    const request = http.createHttp();
    let source: image.ImageSource | undefined;
    let bitmap: image.PixelMap | undefined;
    try {
      const response = await request.request(url, {
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: { 'Referer': 'https://tieba.baidu.com/' },
        connectTimeout: 4500,
        readTimeout: 6500
      });
      if (epoch !== this.forumArtEpoch || response.responseCode < 200 || response.responseCode >= 300 ||
        !(response.result instanceof ArrayBuffer)) {
        return;
      }
      source = image.createImageSource(response.result);
      const size = (await source.getImageInfo()).size;
      const scale: number = Math.min(1, 1440 / size.width, 960 / size.height);
      bitmap = await source.createPixelMap({
        desiredSize: { width: Math.max(1, Math.round(size.width * scale)), height: Math.max(1, Math.round(size.height * scale)) }
      });
      const themeColor: string = color.length > 0 ? this.forumTint(
        parseInt(color.slice(1, 3), 16), parseInt(color.slice(3, 5), 16), parseInt(color.slice(5, 7), 16))
        : await this.pickForumArtColor(bitmap);
      if (epoch === this.forumArtEpoch) {
        this.forumArtColor = themeColor;
        this.forumHeaderArt = bitmap;
        bitmap = undefined;
      }
    } catch (e) {
      // 吧头图加载失败时保留主题色底和吧信息。
    } finally {
      request.destroy();
      source?.release().catch(() => {});
      bitmap?.release().catch(() => {});
    }
  }

  private async pickForumArtColor(bitmap: image.PixelMap): Promise<string> {
    try {
      // 取内容区的代表性色，避开图像边缘的背景与装饰。
      const picker = await effectKit.createColorPicker(bitmap, [0.05, 0.23, 0.95, 0.82]);
      const palette = picker.getTopProportionColors(12);
      const color = palette.find((candidate: effectKit.Color | null): boolean => {
        if (candidate === null) return false;
        const high: number = Math.max(candidate.red, candidate.green, candidate.blue);
        const low: number = Math.min(candidate.red, candidate.green, candidate.blue);
        return high >= 96 && high - low >= 48;
      }) ?? picker.getMainColorSync();
      return color ? this.forumTint(color.red, color.green, color.blue) : '';
    } catch (e) {
      return '';
    }
  }

  private forumTint(red: number, green: number, blue: number): string {
    const scale: number = Math.min(1, 100 / Math.max(1, red, green, blue));
    return '#' + [red, green, blue].map((channel: number): string =>
      Math.round(channel * scale).toString(16).padStart(2, '0')).join('');
  }

  /** 吧头信息就绪（含真实头像）→ 把「最近进入」足迹补上头像并置顶，进吧页「最近进入」即时可见，无需重启 */
  private onForumInfoChanged(): void {
    this.syncForumSignStatus();
    this.refreshFollowedForumSignStatus();
    const url: string = this.forumInfo?.headerImage ?? '';
    if (url !== this.forumArtUrl) {
      this.forumArtUrl = url;
      const epoch: number = ++this.forumArtEpoch;
      this.releaseForumHeaderArt();
      if (url.length > 0) {
        this.loadForumHeaderArt(url, this.forumInfo?.headerImageColor ?? '', epoch);
      }
    }
    if (this.visitAvatarSaved || !this.forumInfo || this.forumName.length === 0 || this.forumInfo.avatar.length === 0) {
      return;
    }
    this.visitAvatarSaved = true;
    HistoryStore.getInstance().recordForumVisit(this.forumName, this.forumId, this.forumInfo.avatar).catch(() => {
    });
  }

  private threadColumns(): number {
    // 派生缓存（2026-09-19，零风险）：本函数每次 build 被调 5~10 次，而内部整条设备判定链
    // （isWideBarFullscreen → isWideBarDevice / isLargeScreenForm → isWideBarDevice + isLargeFoldDevice
    //  / isLargeFoldDevice / isWideBarDevice）每次都会调 display.isFoldable() / getFoldStatus() /
    // getDefaultDisplaySync()，结果却只由 pageWidth / pageHeight / columnMode 决定。
    // 折叠屏展开↔折叠必然改变窗口尺寸 ⇒ 键必变 ⇒ 不会漏翻档。
    const key: string = `${this.pageWidth}|${this.pageHeight}|${this.columnMode}`;
    if (key === this.colCacheKey) {
      return this.colCacheValue;
    }
    const cols: number = this.computeThreadColumns();
    this.colCacheKey = key;
    this.colCacheValue = cols;
    return cols;
  }

  /** 列数真值计算（无缓存）：仅供 threadColumns() 调用，勿直接调用以免绕过缓存 */
  private computeThreadColumns(): number {
    // 窗口闸门最前（2026-09-17 小窗 / 分屏适配）：窗口宽 <600（自由多窗小窗 / 分屏窄窗）一律回落
    // 手机单列档——须在设备恒值分支（大折叠恒 3）之前，防小窗误命中
    // 阔直屏全屏白名单（2026-09-18）：Pura X View（VOL-AL00）等阔直屏竖屏全屏窗口宽仅 ~440vp，
    // 会被本闸门误判成小窗；白名单放行（小窗 / 分屏仍拦，见 Theme.isWideBarFullscreen）
    if (this.pageWidth > 0 && this.pageWidth < Breakpoint.sm && !isWideBarFullscreen(this.pageWidth)) {
      return 1;
    }
    // 「列数调整」（2026-09-18，个性化 → 列数调整）：仅大屏形态（平板 / 阔直屏 / 大折叠展开）生效，
    // 窄窗与手机档已由上面的窗口闸门返回不受影响；默认档 ov=0 → 原样走下面自动适配分支（逐像素零回归）
    if (isLargeScreenForm(this.isWideFormDevice)) {
      const ov: number = overrideColumns(this.columnMode, this.isLandscape);
      if (ov > 0) {
        return ov;
      }
    }
    // 大折叠（docs/TiebaPura大折叠适配.md §4.2）：竖 2 / 横 3（2026-09-17 用户改定，与阔直屏同口径；吧主页与吧搜索态共用）
    if (isLargeFoldDevice()) {
      return this.isLandscape ? 3 : 2;
    }
    // 阔直屏（docs/TiebaPura阔直屏适配.md §4.2，2026-09-17 用户改定）：不依赖宽度阈值（竖屏宽 <600），
    // 竖 1 / 横 3（竖屏回落手机单列档；初版竖 2 作废）
    if (isWideBarDevice()) {
      return this.isLandscape ? 3 : 1;
    }
    if (!this.isWideFormDevice) {
      return 1;
    }
    if (this.pageWidth < Breakpoint.sm) {
      return 1;
    }
    // 2026-09-17 三次拍板：平板**竖屏 2 列**（≥840 竖屏 3 列作废）/ 横屏 3 列（吧搜索态共用）
    return this.isLandscape ? 3 : 2;
  }

  /**
   * 列数标记下发：**无条件写**（单列也写 1）。
   * `cardColumns` 是 AppStorage 全局单值、被多页 `ThreadCard` 的 `@StorageProp` 单向订阅，
   * 只在多列档写会让别的页在单列下按多列几何渲染（§6.1 D1 / D6：折叠屏展开 → 折叠必须回 1）。
   */
  private syncCardColumns(): void {
    // 同值短路（2026-09-18 旋转丝滑）：见 HomeTab 同款说明——同值重写会白触发全屏 ThreadCard 重排
    const next: number = this.threadColumns();
    if (AppStorage.get<number>(CARD_COLUMNS_KEY) !== next) {
      AppStorage.setOrCreate(CARD_COLUMNS_KEY, next);
    }
  }

  /** 把扁平列表按当前列数切成二维行数组（仅列数 > 1 时调用） */
  private threadRows(items: ThreadItem[]): ThreadItem[][] {
    const cols: number = this.threadColumns();
    const rows: ThreadItem[][] = [];
    for (let i: number = 0; i < items.length; i += cols) {
      rows.push(items.slice(i, i + cols));
    }
    return rows;
  }

  /** §4.8 T-D 搜索多列（2026-09-14 改瀑布流）：列索引数组 [0..列数-1]——外层 ForEach 只遍历索引，保证列容器 key 稳定可复用 */
  private searchColIndexes(): number[] {
    const n: number = this.threadColumns();
    const arr: number[] = [];
    for (let i = 0; i < n; i++) {
      arr.push(i);
    }
    return arr;
  }

  /**
   * 搜索结果分桶（方案 B「带滞回的最短列」，2026-09-14，与 §4.9 / §4.10 同款）：
   * 默认按 `i % 列数` 轮转（保序观感），仅当轮转目标列与最短列的估算高差
   * > `THREAD_SEARCH_COL_BALANCE_THRESHOLD` 时改投最短列补位——搜索结果有无图 / 图多图少
   * 长短交错明显，行分组（原实现）会把矮卡下方留白拉大，瀑布流分桶后各列底部收敛。
   * 高度为确定性估算（同步可算、无测量循环）；前缀稳定贪心：结果追加从头重算，旧卡落列不变（不跳位）。
   */
  private searchColumnsData(): ThreadItem[][] {
    const cols: number = this.threadColumns();
    const buckets: ThreadItem[][] = [];
    const heights: number[] = [];
    for (let c = 0; c < cols; c++) {
      buckets.push([]);
      heights.push(0);
    }
    // 列宽（估算换行 / 图片比例用）：屏宽 − 结果区左右 padding(12×2) − 列间 gap(6×(cols−1))
    const colWidth: number = (this.currentWidth - 24 - 6 * (cols - 1)) / cols;
    const items: ThreadItem[] = this.searchThreads();
    for (let i = 0; i < items.length; i++) {
      let target: number = i % cols;
      let shortest: number = 0;
      for (let c = 1; c < cols; c++) {
        if (heights[c] < heights[shortest]) {
          shortest = c;
        }
      }
      if (heights[target] - heights[shortest] > THREAD_SEARCH_COL_BALANCE_THRESHOLD) {
        target = shortest;
      }
      buckets[target].push(items[i]);
      heights[target] += this.estimateSearchCardHeight(items[i], colWidth) + 6;
    }
    return buckets;
  }

  /**
   * 搜索结果卡估算高（vp，仅供列均衡分桶，不求像素准只求相对准；**按多列档口径**，
   * 与 `ThreadCard` 的 `cardColumns > 1` 渲染分支同式）：
   * 头像行 40 + 互动行 36 + 卡内 padding/留白 48 为常数底数 124；
   * 标题 ≤2 行（fs16→行高 22）、摘要 ≤2 行（fs14→行高 20），每行字数按列宽折算；
   * 单图 = min(列宽 / 1.6, 220)（aspectRatio 1.6 + maxHeight 封顶，与渲染同式）；
   * 多图宫格 = ⌈n/3⌉ 行 × min(列宽 / 3, 140)（1:1 格 + maxHeight 封顶，同渲染）。
   */
  private estimateSearchCardHeight(item: ThreadItem, colWidth: number): number {
    let h: number = 124;
    const title: string = item.title ?? '';
    if (title.length > 0) {
      const cpl: number = Math.max(8, Math.floor(colWidth / 16));
      h += Math.min(Math.ceil(title.length / cpl), 2) * 22 + 6;
    }
    const abs: string = item.abstract ?? '';
    if (abs.length > 0) {
      const cpl2: number = Math.max(10, Math.floor(colWidth / 14));
      h += Math.min(Math.ceil(abs.length / cpl2), 2) * 20 + 6;
    }
    const n: number = (item.images ?? []).length;
    if (n === 1) {
      h += Math.min(colWidth / 1.6, 220) + 6;
    } else if (n > 1) {
      const cellH: number = Math.min(colWidth / 3, 140);
      h += Math.ceil(n / 3) * cellH + 6;
    }
    return h;
  }


  /** 末行补空位下标：不足 cols 时用等宽空白补齐，避免最后一张卡被拉伸占满整行（§6.1 A2） */
  private threadBlankSlots(rowLen: number): number[] {
    const cols: number = this.threadColumns();
    const slots: number[] = [];
    for (let i: number = rowLen; i < cols; i++) {
      slots.push(i);
    }
    return slots;
  }

  /**
   * 数据源中首个置顶项的 tid：单列档（WaterFlow 逐格渲染）把「置顶合并块」挂在它对应的格子上，
   * 其余置顶项渲染 0 高占位（rowsGap=0 故不产生间距）—— 从而在虚拟容器里保住改造前的合并卡样式。
   */
  private firstPinnedTid(): string {
    const p: ThreadItem[] = this.pinnedThreads();
    return p.length > 0 ? p[0].tid : '';
  }

  private pinnedThreads(): ThreadItem[] {
    // 派生缓存（2026-09-19，零风险自失效）：键 = threads 引用 + 排序档；
    // threads 全程整体赋值 ⇒ 引用变即内容变。返回值仅被读取（.length / threadRows / ForEach），无调用方 mutate。
    if (this.pinnedCacheSrc === this.threads && this.pinnedCacheSort === this.selectedSort) {
      return this.pinnedCacheValue;
    }
    // On "精选" tab (sort=2), don't separate - show everything as ThreadCard for easy browsing
    const result: ThreadItem[] = this.selectedSort === 2
      ? []
      : this.threads.filter((t: ThreadItem) => t.isTop === true);
    this.pinnedCacheSrc = this.threads;
    this.pinnedCacheSort = this.selectedSort;
    this.pinnedCacheValue = result;
    return result;
  }

  private normalThreads(): ThreadItem[] {
    // 派生缓存（2026-09-19，零风险自失效）：同 pinnedThreads
    if (this.normalCacheSrc === this.threads && this.normalCacheSort === this.selectedSort) {
      return this.normalCacheValue;
    }
    // On "精选" tab (sort=2), show ALL threads as normal cards
    // On other tabs: show non-置顶 threads as normal cards (精品 threads included)
    const result: ThreadItem[] = this.selectedSort === 2
      ? this.threads
      : this.threads.filter((t: ThreadItem) => t.isTop !== true);
    this.normalCacheSrc = this.threads;
    this.normalCacheSort = this.selectedSort;
    this.normalCacheValue = result;
    return result;
  }

  /**
   * 本吧搜索结果（空关键词 / 取数中 / 无结果 / 结果列表 + 进度，复用 ThreadCard）。
   * 服务端模式一次出整页命中；本地模式逐轮扫描增长。无结果且仍在取数时显示"正在搜索"，
   * 而不是瞬时"未找到"；结果不满一屏时由 maybeAutoContinueSearch 自动续取，无需用户滑动。
   */
  @Builder
  PinnedForumGroup(items: ThreadItem[]) {
    Column({ space: 8 }) {
      if (items.length > 0) {
        Row({ space: 7 }) {
          Text('置顶')
            .fontSize(fs(10, this.fontScale))
            .fontColor('#56768F')
            .border({ width: 0.5, color: '#A9BACA' })
            .borderRadius(3)
            .padding({ left: 3, right: 3, top: 2, bottom: 2 })
          Text(items[0].title)
            .fontSize(fs(14, this.fontScale))
            .fontColor(Theme.textPrimary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .onClick(() => { this.openThread(items[0].tid); })
          if (items.length > 1) {
            Row({ space: 3 }) {
              Text('共' + items.length + '条').fontSize(fs(11, this.fontScale)).fontColor(Theme.textPrimary(this.isDark))
              SymbolGlyph(this.pinnedExpanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                .fontSize(10)
                .fontColor([Theme.textPrimary(this.isDark)])
            }
            .padding({ left: 8, right: 8, top: 5, bottom: 5 })
            .backgroundColor(Theme.bg(this.isDark))
            .borderRadius(Radius.full)
            .id('forum_pinned_toggle')
            .onClick(() => { this.pinnedExpanded = !this.pinnedExpanded; })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.selectedSort === 0 && (items[0].firstImage || items[0].abstract.length > 0)) {
          Row({ space: 8 }) {
            if ((items[0].firstImage ?? '').length > 0) {
              Image(items[0].firstImage!)
                .width(104)
                .height(66)
                .borderRadius(7)
                .objectFit(ImageFit.Cover)
                .id('forum_pinned_image')
                .accessibilityText('查看置顶帖图片')
                .onClick(() => {
                  const urls: string[] = items[0].images ?? [];
                  openForumImagePreview(this.getUIContext(), urls.length > 0 ? urls : [items[0].firstImage!], 0);
                })
            }
            Text(items[0].abstract)
              .fontSize(fs(13, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDark))
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .onClick(() => { this.openThread(items[0].tid); })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          Row({ space: 8 }) {
            Text(items[0].author)
              .fontSize(fs(11, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDark))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.ellipsis_message_1')).fontSize(15).fontColor([Theme.textSecondary(this.isDark)])
              Text(String(items[0].replyNum)).fontSize(fs(11, this.fontScale)).fontColor(Theme.textSecondary(this.isDark))
            }
            .onClick(() => { this.openThread(items[0].tid); })
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.hand_thumbsup')).fontSize(15)
                .fontColor([items[0].isLiked ? Theme.brand() : Theme.textSecondary(this.isDark)])
              Text((items[0].likeCount ?? 0) > 0 ? String(items[0].likeCount) : '赞')
                .fontSize(fs(11, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .onClick(() => { this.handleLike(items[0].tid, items[0].postId ?? '', items[0].isLiked ?? false); })
          }
          .width('100%')
        }
        if (this.pinnedExpanded) {
          ForEach(items.slice(1), (item: ThreadItem) => {
            Row({ space: 7 }) {
              Text('置顶')
                .fontSize(fs(10, this.fontScale))
                .fontColor('#56768F')
              Text(item.title)
                .fontSize(fs(14, this.fontScale))
                .fontColor(Theme.textPrimary(this.isDark))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 4, bottom: 4 })
            .onClick(() => { this.openThread(item.tid); })
          }, (item: ThreadItem) => item.tid)
        }
      }
    }
    .width('100%')
    .padding(10)
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(FORUM_CARD_RADIUS_BASE * this.cardRadiusScale)
    .margin({ bottom: 6 })
  }

  @Builder
  SearchResultsBuilder() {
    Column({ space: 6 }) {
      if (this.searchKeyword.trim().length === 0) {
        Column({ space: Spacing.md }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontColor([$r('sys.color.icon_tertiary')])
            .fontSize(fs(40, this.fontScale))
          Text('输入关键词搜索本吧帖子')
            .fontSize(fs(14, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
        .width('100%')
        .height(320)
        .justifyContent(FlexAlign.Center)
      } else if (this.searchThreads().length === 0 && this.searchFetching) {
        // 首轮扫描中：先给"正在搜索"，避免瞬时"未找到相关帖子"误导
        Column({ space: Spacing.md }) {
          LoadingView({ message: '正在搜索本吧帖子...' }).height(120)
        }
        .width('100%')
        .height(320)
        .justifyContent(FlexAlign.Center)
      } else if (this.searchThreads().length === 0) {
        Column({ space: Spacing.md }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontColor([$r('sys.color.icon_tertiary')])
            .fontSize(fs(40, this.fontScale))
          Text('未找到相关帖子')
            .fontSize(fs(14, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
          if (this.searchExhausted) {
            Text(this.searchEmptyHint())
              .fontSize(fs(12, this.fontScale))
              .fontColor(Theme.textTertiary(this.isDark))
          }
        }
        .width('100%')
        .height(320)
        .justifyContent(FlexAlign.Center)
      } else {
        // 进度行：让"找到多少、扫了多少"可见，避免长时间扫描被误认为卡住
        Row() {
          Text(this.searchStatusText())
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textTertiary(this.isDark))
        }
        .width('100%')
        .padding({ left: 4, top: 8, bottom: 2 })

        if (this.threadColumns() > 1) {
          // §4.8 T-D 二次更正（2026-09-14）：多列由「行分组 + 末行补空位」改为**列内独立堆叠瀑布流**
          //（与首页 / 收藏页 / 详情页同款观感）——行分组会把矮卡下方留白拉大（有无图 / 图多图少交错时尤甚）。
          // 结构照收藏页五轮教训：外层 ForEach **只遍历列索引**（key 稳定 → 列容器复用），
          // 内层数据源**直读状态源** `searchColumnsData()[colIdx]`（不用外层传入的 col，否则复用断链不更新）。
          Row({ space: 6 }) {
            ForEach(this.searchColIndexes(), (colIdx: number) => {
              Column({ space: 6 }) {
                ForEach(this.searchColumnsData()[colIdx], (item: ThreadItem) => {
                  Column() {
                    ThreadCard({
                      forumScoped: true,
                      item: {
                        tid: item.tid, postId: item.postId ?? '',
                        title: item.title, forumName: item.forumName,
                        forumAvatar: item.forumAvatar ?? '',
                        author: item.author,
                        authorAvatar: item.authorAvatar ?? '',
                        authorId: item.authorId ?? '',
                        replyNum: item.replyNum, likeCount: item.likeCount ?? 0,
                        isLiked: item.isLiked ?? false,
                        abstract: item.abstract,
                        firstImage: item.firstImage ?? '', images: item.images ?? [],
                        imageThumbs: item.imageThumbs ?? [],
                        createTime: item.createTime, isTop: item.isTop, isGood: item.isGood,
                      } as ThreadItemData,
                      onTap: (tid: string) => this.openThread(tid),
                      onLike: (tid: string, postId: string, liked: boolean) => this.handleLike(tid, postId, liked),
                      onShare: (d: ThreadSharePayload) => this.shareThread(d),
                      onComment: (tid: string) => this.openThread(tid),
                      onAvatarTap: (id: string, name: string) => this.openUserProfile(id, name)
                    })
                  }
                  // 新增卡片淡入（已有卡片按 key 复用，加载下一批不闪）
                  .transition(TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseOut }))
                },
                  (item: ThreadItem) => `search_${item.tid}_${item.authorId ?? ''}_${item.authorAvatar ?? ''}_${item.author}_${item.isLiked ? 1 : 0}_${item.likeCount ?? 0}_${item.replyNum}`)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }, (colIdx: number) => `scol_${colIdx}`)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else {
          // 单列档：逐像素保持改造前结构
          ForEach(this.searchThreads(), (item: ThreadItem) => {
            ThreadCard({
              forumScoped: true,
              item: {
                tid: item.tid, postId: item.postId ?? '',
                title: item.title, forumName: item.forumName,
                forumAvatar: item.forumAvatar ?? '',
                author: item.author,
                authorAvatar: item.authorAvatar ?? '',
                authorId: item.authorId ?? '',
                replyNum: item.replyNum, likeCount: item.likeCount ?? 0,
                isLiked: item.isLiked ?? false,
                abstract: item.abstract,
                firstImage: item.firstImage ?? '', images: item.images ?? [],
                imageThumbs: item.imageThumbs ?? [],
                createTime: item.createTime, isTop: item.isTop, isGood: item.isGood,
              } as ThreadItemData,
              onTap: (tid: string) => this.openThread(tid),
              onLike: (tid: string, postId: string, liked: boolean) => this.handleLike(tid, postId, liked),
              onShare: (d: ThreadSharePayload) => this.shareThread(d),
              onComment: (tid: string) => this.openThread(tid),
              onAvatarTap: (id: string, name: string) => this.openUserProfile(id, name)
            })
          },
            // 键必须覆盖后台补数据的字段：ForEach 仅在键变化时重建子组件，
            // 若只用 tid（固定键），详情补齐回来的 authorId/头像/点赞数会被复用旧组件吞掉，
            // 表现为"头像仍是字母占位、点赞恒 0、点作者不跳转"。
            (item: ThreadItem) => `search_${item.tid}_${item.authorId ?? ''}_${item.authorAvatar ?? ''}_${item.author}_${item.isLiked ? 1 : 0}_${item.likeCount ?? 0}_${item.replyNum}`)
        }

        // 结果底部状态：扫描进度 / 继续搜索 / 已扫到底（与列表翻页底部同构）
        Row() {
          if (this.searchFetching) {
            LoadingView({ message: '正在搜索更多...' }).height(40)
          } else if (this.searchExhausted) {
            Text(this.searchFooterEndText())
              .fontSize(fs(13, this.fontScale))
              .fontColor(Theme.textTertiary(this.isDark))
          } else {
            Text('下滑加载更多匹配结果')
              .fontSize(fs(13, this.fontScale))
              .fontColor(Theme.textTertiary(this.isDark))
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: Spacing.md, bottom: Spacing.md })
      }
    }
    .width('100%')
    .padding({ left: this.cardSideInset(), right: this.cardSideInset() })
  }

  private async handleRefresh(fromPull: boolean = false): Promise<void> {
    if (this.refreshing) {
      console.info(`[REFRESH] skip (busy) sort=${this.selectedSort}`);
      return;
    }
    this.refreshing = true;
    const myToken: number = this.loadToken;
    const myKey: string = this.sortKey();
    const t0: number = Date.now();
    console.info(`[REFRESH] start sort=${this.selectedSort}`);
    try {
      // 热门档刷新同样重建「客户端热度榜」（与「最新·按回复时间」区分）；其余档刷新第 1 页
      const isHotRank: boolean = this.selectedSort === 0;
      const result = await this.withRefreshTimeout(
        isHotRank
          ? TiebaService.getInstance().fetchForumHotRank(this.forumName)
          : TiebaService.getInstance().fetchForumThreads(this.forumName, 1, this.effectiveSort(), false)
      );
      if (myToken !== this.loadToken || myKey !== this.sortKey()) {
        return;
      }
      this.loadToken++;
      this.lastPrefetchPage = -1;
      this.loadMoreFailed = false;
      this.prefetchGate.reset();
      this.page = isHotRank ? HOT_RANK_PAGES : 1;
      this.hasMore = result.list.length > 0;
      this.stalledPages = 0;
      this.threads = result.list;
      this.loadState = result.list.length > 0 ? LoadState.Success : LoadState.Empty;
      const header = TiebaService.getInstance().getCachedForumHeader(this.forumName);
      if (header) {
        this.forumInfo = header;
      }
      // 刷新后回到顶部，立即看到最新内容
      this.listScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: 300, curve: Curve.EaseOut } });
      // 刷新同样走后台昵称校准 + 回写缓存
      if (result.list.length > 0) {
        this.enrichInBackground(result.list);
        this.saveForumCache(result.list);
      }
      console.info(`[REFRESH] ok sort=${this.selectedSort} n=${result.list.length} cost=${Date.now() - t0}ms`);
      // 下拉刷新路径不弹「刷新成功」（下拉手势本身即反馈，每次弹 toast 过噪）；重复点排序仍保留
      if (!fromPull) {
        this.getUIContext().getPromptAction().showToast({ message: '刷新成功' });
      }
    } catch (e) {
      if (myToken !== this.loadToken || myKey !== this.sortKey()) {
        return;
      }
      const msg = (e as Error).message ?? '刷新失败';
      console.info(`[REFRESH] fail sort=${this.selectedSort} cost=${Date.now() - t0}ms err=${msg}`);
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } finally {
      this.refreshing = false;
    }
  }

  /** 刷新总超时兜底：弱网/接口挂起时最多等 8 秒。
   *  刷新钮移除后界面已无转圈图标，兜底的目的变成「别让 busy 门被挂起的请求长期占住、
   *  导致后续重复点击排序（回顶刷新）持续被短路」。 */
  private withRefreshTimeout<T>(promise: Promise<T>): Promise<T> {
    return new Promise<T>((resolve: (v: T) => void, reject: (e: Error) => void) => {
      const timer: number = setTimeout(() => {
        reject(new Error('刷新超时，请检查网络'));
      }, 8000);
      promise.then((value: T) => {
        clearTimeout(timer);
        resolve(value);
      }).catch((e: Error) => {
        clearTimeout(timer);
        reject(e);
      });
    });
  }

  /**
   * 当前吧是否处于「未关注」态（吧信息未加载时视为未知，按已关注展示原逻辑）。
   * 未关注时签到钮改显「未关注」，点击先引导关注；关注成功后 isLike 变化触发刷新，
   * 关注成功后显示读取到的签到状态。
   */
  private forumUnfollowed(): boolean {
    return this.forumInfo !== null && !this.forumInfo.isLike;
  }

  private signButtonLabel(): string {
    if (this.forumUnfollowed()) {
      return '未关注';
    }
    if (this.forumSignedToday) {
      return this.signDays > 0 ? `已签${this.signDays}天` : '已签到';
    }
    return this.forumSignKnown ? '未签到' : '签到';
  }

  private async handleSignIn(): Promise<void> {
    if (this.forumSignInFlight) {
      return;
    }
    this.forumSignInFlight = true;
    try {
      this.syncForumSignStatus();
      const localDays: number = this.forumSignedToday ? 0 : await ForumSignStore.loadSignDays(this.forumName);
      if (localDays > 0 && !this.forumSignedToday) {
        this.forumSignedToday = true;
        this.signDays = localDays;
      }
      if (this.forumSignedToday) {
        this.getUIContext().getPromptAction().showToast({ message: this.signDays > 0
          ? `今日已签到，已连续签到${this.signDays}天` : '今日已签到' });
        return;
      }
      this.getUIContext().getPromptAction().showToast({ message: '签到中...' });
      const result = await TiebaService.getInstance().signForum(this.forumName);
      this.forumSignedToday = true;
      this.forumSignKnown = true;
      this.signDays = result.signDays > 0 ? result.signDays : this.signDays;
      await ForumSignStore.saveSignDays(this.forumName, this.signDays);
      const bonusMsg = result.bonusNum > 0 ? `，获得${result.bonusNum}经验` : '';
      const streak: string = this.signDays > 0 ? `已连续签到${this.signDays}天` : '';
      this.getUIContext().getPromptAction().showToast({
        message: `签到成功！${streak}${bonusMsg}`
      });
      // Refresh forum header to get updated score
      const header = TiebaService.getInstance().getCachedForumHeader(this.forumName);
      if (header) {
        this.forumInfo = header;
      }
    } catch (e) {
      const msg = (e as Error).message ?? '签到失败，请稍后重试';
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } finally {
      this.forumSignInFlight = false;
    }
  }

  private syncForumSignStatus(): void {
    const date: string = ForumSignStore.todayStamp();
    if (date !== this.forumSignDate) {
      this.forumSignDate = date;
      this.forumSignedToday = false;
      this.forumSignKnown = false;
      this.signDays = 0;
    }
    this.applyForumSignStatus(TiebaService.getInstance().getCachedForumSignStatus(this.forumName));
  }

  private applyForumSignStatus(remote: ForumSignStatus | undefined): void {
    if (!remote) {
      return;
    }
    this.forumSignKnown = true;
    if (remote.signed) {
      this.forumSignedToday = true;
      if (remote.days > 0) {
        this.signDays = remote.days;
      }
    }
  }

  private async refreshFollowedForumSignStatus(): Promise<void> {
    if (this.forumSignedToday || this.forumSignLookupInFlight || this.forumUnfollowed()) {
      return;
    }
    const date: string = this.forumSignDate;
    const forumId: string = this.forumInfo?.forumId || this.forumId;
    this.forumSignLookupInFlight = true;
    try {
      const status = await TiebaService.getInstance().fetchFollowedForumSignStatus(this.forumName, forumId);
      if (date === this.forumSignDate && date === ForumSignStore.todayStamp()) {
        this.applyForumSignStatus(status);
      }
    } finally {
      this.forumSignLookupInFlight = false;
    }
    if (date === this.forumSignDate && !this.forumSignKnown && forumId.length === 0 &&
      (this.forumInfo?.forumId ?? '').length > 0) {
      this.refreshFollowedForumSignStatus();
    }
  }

  private restoreSignState(): void {
    this.syncForumSignStatus();
    const date: string = this.forumSignDate;
    ForumSignStore.loadSignDays(this.forumName).then((days: number) => {
      if (days > 0 && date === this.forumSignDate && !this.forumSignedToday) {
        this.forumSignedToday = true;
        this.forumSignKnown = true;
        this.signDays = days;
      }
    }).catch((): void => {
    });
    this.refreshFollowedForumSignStatus();
  }

  /**
   * 点赞状态局部更新（不可变）：列表与搜索池共用。
   * 必须保留 authorId / authorNameShowMissing —— 旧实现重建对象时漏掉 authorId，
   * 会导致点赞后该卡片的作者头像/昵称点击因 authorId 丢失而无法跳转用户主页。
   */
  private withLikeState(t: ThreadItem, tid: string, liked: boolean): ThreadItem {
    if (t.tid !== tid) {
      return t;
    }
    return {
      tid: t.tid, postId: t.postId, forumId: t.forumId,
      title: t.title, forumName: t.forumName, forumAvatar: t.forumAvatar,
      author: t.author, authorId: t.authorId, authorAvatar: t.authorAvatar,
      authorNameShowMissing: t.authorNameShowMissing,
      replyNum: t.replyNum,
      likeCount: (t.likeCount ?? 0) + (liked ? 1 : -1),
      isLiked: liked,
      abstract: t.abstract, firstImage: t.firstImage,
      images: t.images, createTime: t.createTime,
      isTop: t.isTop, isGood: t.isGood,
      isFeatured: t.isFeatured,
    } as ThreadItem;
  }

  private async handleLike(tid: string, postId: string, liked: boolean): Promise<void> {
    try {
      const result = await TiebaService.getInstance().togglePostAgree(tid, postId, liked);
      if (result) {
        // 更新帖子列表中的点赞状态（不可变更新）
        this.threads = this.threads.map((t: ThreadItem): ThreadItem => this.withLikeState(t, tid, liked));
        // 搜索态结果池同样需要更新，否则吧内搜索页点赞后数字/心形不变化
        if (this.searchMode) {
          this.searchPool = this.searchPool.map((t: ThreadItem): ThreadItem => this.withLikeState(t, tid, liked));
          this.searchPoolVersion++;
        }
      }
    } catch (e) {
      const msg = (e as Error).message ?? '操作失败，请稍后重试';
      this.getUIContext().getPromptAction().showToast({ message: msg });
    }
  }

}
