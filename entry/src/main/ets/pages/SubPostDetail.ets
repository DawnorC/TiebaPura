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

import { SubPostDetail as SubPostDetailModel, FloorItem, CommentItem, ContentFragment, ContentFragmentType } from '../model/DataModel';
import { common, Want } from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { TiebaService } from '../service/TiebaService';
import {
  Theme, Spacing, Radius, isDarkMode, ImmBlur, ImmMaterial, fs, overlayCardWidth,
  DEFAULT_CARD_RADIUS_SCALE
} from '../common/Theme';
import { LoadingView, EmptyView, ErrorView } from '../components/CommonComponents';
import { EmojiLoader } from '../network/EmojiLoader';
import image from '@ohos.multimedia.image';

const SUBPOST_IMAGE_GRID_MAX_WIDTH: number = 336;

export interface SubPostPanelRequest {
  tid: string;
  parentPid: string;
  parentFloor: number;
  forumId: string;
  parent?: FloorItem;
  notifyCommentPid?: string;
  notifyReplyerId?: string;
  notifyContent?: string;
}

@Component
export struct SubPostReplyPanel {
  request: SubPostPanelRequest = { tid: '', parentPid: '', parentFloor: 0, forumId: '' };
  onClose: () => void = () => {};
  onReply?: (comment?: CommentItem) => void;
  onParentLikeChanged: (floorId: string, liked: boolean, count: number) => void = () => {};

  @StorageLink('cardRadiusScale') cardRadiusScale: number = DEFAULT_CARD_RADIUS_SCALE;
  @StorageLink('fontScale') fontScale: number = 1.0;
  @State isDark: boolean = isDarkMode();
  @State parent: FloorItem | null = null;
  @State parentLiked: boolean = false;
  @State parentLikeCount: number = 0;
  @State commentsState: CommentItem[] = [];
  @State loading: boolean = false;
  @State hasMore: boolean = true;
  @State errorMsg: string = '';
  @State highlightCommentId: string = '';
  private page: number = 0;
  private pageAlive: boolean = true;
  private locatingNotify: boolean = false;
  private likeInFlight: boolean = false;
  private locateScrollTimer: number = -1;
  private highlightResetTimer: number = -1;
  private scroller: Scroller = new Scroller();

  @State readyEmojiUrls: string[] = [];
  @State failedEmojiUrls: string[] = [];
  /**
   * 长按复制（docs/帖子详细页长按复制文字功能补全.md）：各正文 Text 的「复制重建纪元」。
   * 复制完成后自增对应 key → RichTextContent 内单元素 ForEach 的 key 变化 → Text 节点整体重建
   * → 选中态随节点销毁清除。用 per-region key 而非共享 selection(start,end) 绑定：
   * selection 属性绑共享 @State 会把同一段选中范围套到所有绑定 Text 上（跨楼层串扰）；
   * 纪元重建只重建被复制的那一个节点。Record 更新须整体赋新对象触发重渲染。
   */
  @State copyEpochs: Record<string, number> = {};

  /** 读取某正文区域的复制重建纪元（缺省 0；ForEach key 生成用） */
  private copyEpochOf(regionKey: string): number {
    return this.copyEpochs[regionKey] ?? 0;
  }

  /** 复制成功回调：toast 提示 + 自增纪元清除该 Text 的选中态 */
  private onTextCopied(regionKey: string): void {
    this.getUIContext().getPromptAction().showToast({ message: '复制成功' });
    // ArkTS 禁止对象展开（arkts-no-spread），Record 拷贝走 Object.keys 逐键赋值；
    // 其余 key 保留原值（纪元不变 → 对应 Text 节点不重建），只有被复制的区域自增
    const next: Record<string, number> = {};
    Object.keys(this.copyEpochs).forEach((k: string) => {
      next[k] = this.copyEpochs[k];
    });
    next[regionKey] = (this.copyEpochs[regionKey] ?? 0) + 1;
    this.copyEpochs = next;
  }
  @State pendingLinkUrl: string = '';
  @State showLinkDialog: boolean = false;

  private hasReadyEmoji(url: string): boolean {
    return EmojiLoader.has(url) || (this.readyEmojiUrls.indexOf(url) !== -1);
  }
  private hasFailedEmoji(url: string): boolean {
    return this.failedEmojiUrls.indexOf(url) !== -1;
  }
  private prefetchEmojisWithLoader(urls: string[]): void {
    for (const u of urls ?? []) {
      if (!u || u.length === 0) continue;
      if (EmojiLoader.has(u)) {
        if (this.readyEmojiUrls.indexOf(u) === -1) {
          this.readyEmojiUrls = [...this.readyEmojiUrls, u];
        }
        continue;
      }
      if (this.failedEmojiUrls.indexOf(u) !== -1) continue;
      EmojiLoader.ensure(u).then(() => {
        if (this.readyEmojiUrls.indexOf(u) === -1) {
          this.readyEmojiUrls = [...this.readyEmojiUrls, u];
        }
      }).catch(() => {
        if (this.failedEmojiUrls.indexOf(u) === -1) {
          this.failedEmojiUrls = [...this.failedEmojiUrls, u];
        }
      });
    }
  }
  private uniqueEmojiUrls(fragments: ContentFragment[]): string[] {
    const out: string[] = [];
    const seen: Record<string, boolean> = {};
    for (const f of fragments ?? []) {
      if (f.type === ContentFragmentType.EMOJI && f.imageUrl && f.imageUrl.length > 0) {
        if (!seen[f.imageUrl]) {
          seen[f.imageUrl] = true;
          out.push(f.imageUrl);
        }
      }
    }
    return out;
  }

  aboutToAppear(): void {
    this.isDark = isDarkMode();
    if (this.request.parent) {
      this.applyParentReply(this.request.parent);
    }
    this.loadNextPage().then(() => { this.locateNotifyTarget(); });
  }

  aboutToDisappear(): void {
    this.pageAlive = false;
    clearTimeout(this.locateScrollTimer);
    clearTimeout(this.highlightResetTimer);
  }

  private applyParentReply(floor: FloorItem): void {
    this.parent = floor;
    this.parentLiked = floor.isLiked === true;
    this.parentLikeCount = floor.likeCount ?? 0;
  }

  private async loadNextPage(): Promise<boolean> {
    if (!this.pageAlive || this.loading || !this.hasMore) {
      return false;
    }
    this.loading = true;
    this.errorMsg = '';
    try {
      const result: SubPostDetailModel = await TiebaService.getInstance().fetchSubPostDetail(
        this.request.tid, this.request.parentPid, this.request.forumId, this.request.parentFloor, this.page + 1);
      if (!this.pageAlive) {
        return false;
      }
      if (this.page === 0 && (!this.parent || result.parent.contentText.length > 0 || result.parent.images.length > 0)) {
        this.applyParentReply(result.parent);
      }
      const seen: Set<string> = new Set(this.commentsState.map((comment: CommentItem): string => comment.commentId));
      const added: CommentItem[] = result.comments.filter((comment: CommentItem): boolean => {
        if (seen.has(comment.commentId)) {
          return false;
        }
        seen.add(comment.commentId);
        return true;
      });
      this.page++;
      this.commentsState = [...this.commentsState, ...added];
      this.hasMore = result.hasMore && added.length > 0;
      return true;
    } catch (e) {
      if (this.pageAlive) {
        this.errorMsg = (e as Error).message ?? '楼中楼加载失败，请稍后重试';
      }
      return false;
    } finally {
      if (this.pageAlive) {
        this.loading = false;
      }
    }
  }

  private async locateNotifyTarget(): Promise<void> {
    if (!this.request.notifyCommentPid && !(this.request.notifyReplyerId && this.request.notifyContent)) {
      return;
    }
    this.locatingNotify = true;
    try {
      for (let attempt = 0; attempt <= 6 && this.pageAlive; attempt++) {
        const found = this.commentsState.find((comment: CommentItem): boolean => {
          return comment.commentId === this.request.notifyCommentPid ||
            (this.request.notifyReplyerId !== undefined && this.request.notifyContent !== undefined &&
              comment.authorId === this.request.notifyReplyerId && comment.content.trim() === this.request.notifyContent.trim());
        });
        if (found) {
          this.flashHighlightComment(found.commentId);
          return;
        }
        if (attempt === 6 || !this.hasMore || !await this.loadNextPage()) {
          return;
        }
      }
    } finally {
      this.locatingNotify = false;
    }
  }

  private flashHighlightComment(commentId: string): void {
    this.highlightCommentId = commentId;
    this.locateScrollTimer = setTimeout(() => {
      if (!this.pageAlive) {
        return;
      }
      try {
        const utils = this.getUIContext().getComponentUtils();
        const target = utils.getRectangleById('spc_' + commentId);
        const viewport = utils.getRectangleById('subpost_scroll_content');
        const top = this.getUIContext().px2vp(target.windowOffset.y - viewport.windowOffset.y);
        this.scroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, this.scroller.currentOffset().yOffset + top - 8),
          animation: true });
      } catch (e) {
        // 节点未完成布局时仍保留高亮，用户可自行滚动。
      }
    }, 260);
    this.highlightResetTimer = setTimeout(() => {
      if (this.pageAlive) {
        this.highlightCommentId = '';
      }
    }, 2600);
  }

  build() {
    Stack() {
      Column() {
        Stack() {
          Text(this.request.parentFloor > 0 ? this.request.parentFloor + '楼的回复'
            : (this.parent?.floor ?? 0) > 0 ? this.parent!.floor + '楼的回复' : '楼中楼回复')
            .fontSize(fs(17, this.fontScale))
            .fontColor(Theme.textPrimary(this.isDark))
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(20)
              .fontColor([Theme.textSecondary(this.isDark)])
          }
          .width(44)
          .height(44)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .position({ right: 0, top: 4 })
          .id('subpost_sheet_close')
          .accessibilityText('关闭楼中楼')
          .onClick(() => this.onClose())
        }
        .width('100%')
        .height(52)

        Scroll(this.scroller) {
          Column() {
            if (this.parent) {
              this.ParentReply(this.parent)
              Divider()
                .strokeWidth(4)
                .color(Theme.bg(this.isDark))
            }
            ForEach(this.commentsState, (comment: CommentItem) => {
              this.NestedReply(comment)
            }, (comment: CommentItem) => comment.commentId + '_' + (comment.isLiked ? '1' : '0') + '_' + (comment.likeCount ?? 0))
            if (this.loading) {
              LoadingView({ message: '正在加载回复…' }).height(64)
            } else if (this.errorMsg.length > 0) {
              ErrorView({ message: this.errorMsg, onRetry: () => { this.loadNextPage(); } }).height(120)
            } else if (!this.hasMore && this.commentsState.length === 0) {
              EmptyView({ message: '当前楼层暂无回复' }).height(120)
            }
          }
          .width('100%')
          .constraintSize({ minHeight: '100%' })
        }
        .layoutWeight(1)
        .width('100%')
        .id('subpost_scroll_content')
        .scrollBar(BarState.Off)
        .onReachEnd(() => {
          if (!this.locatingNotify && this.errorMsg.length === 0) {
            this.loadNextPage();
          }
        })

        if (this.onReply !== undefined) {
          Divider().strokeWidth(0.5).color(Theme.divider(this.isDark))
          Row() {
            Text('发贴千百度 文明第一步')
              .fontSize(fs(14, this.fontScale))
              .fontColor(Theme.textTertiary(this.isDark))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .height(34)
          .width('calc(100% - 24vp)')
          .padding({ left: 14, right: 14 })
          .margin({ top: 8, bottom: 8 })
          .accessibilityText('回复，跳转官方贴吧')
          .onClick(() => { this.onReply?.(); })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: 12 })
      .backgroundColor(Theme.bgCard(this.isDark))
      if (this.showLinkDialog) {
        this.LinkConfirmDialog()
      }
    }
    .width('100%')
    .height('100%')
    .id('subpost_reply_sheet')
  }

  @Builder
  ReplyAuthor(author: string, authorId: string, level: number, isAuthor: boolean) {
    Row({ space: 5 }) {
      Text(author || '贴吧用户')
        .fontSize(fs(14, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '74%' })
        .onClick(() => this.openUserProfile(authorId, author))
      if (level > 0) {
        Text('Lv.' + level)
          .fontSize(fs(9, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .backgroundColor(Theme.levelColor(level))
          .borderRadius(Radius.sm)
          .padding({ left: 4, right: 4 })
      }
      if (isAuthor) {
        Text('楼主')
          .fontSize(fs(10, this.fontScale))
          .fontColor(Theme.brand())
      }
    }
    .width('100%')
  }

  @Builder
  ReplyMetadata(label: string, liked: boolean, likeCount: number, onLike: () => void, onReply: () => void) {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(fs(11, this.fontScale))
        .fontColor(Theme.textTertiary(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.onReply !== undefined) {
        Text('回复')
          .fontSize(fs(11, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .onClick(onReply)
      }
      Blank()
      Row({ space: 3 }) {
        SymbolGlyph($r('sys.symbol.hand_thumbsup'))
          .fontSize(14)
          .fontColor([liked ? Theme.brand() : Theme.textTertiary(this.isDark)])
        Text(likeCount > 0 ? String(likeCount) : '赞')
          .fontSize(fs(11, this.fontScale))
          .fontColor(liked ? Theme.brand() : Theme.textTertiary(this.isDark))
      }
      .height(24)
      .accessibilityText(liked ? '取消点赞' : '点赞')
      .onClick(onLike)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ParentReply(floor: FloorItem) {
    Row({ space: 8 }) {
      this.Avatar(floor.authorAvatar ?? '', floor.author, 34, floor.authorId ?? '')
      Column({ space: 4 }) {
        this.ReplyAuthor(floor.author, floor.authorId ?? '', floor.level ?? 0, floor.isAuthor)
        if (floor.contentText.length > 0 || (floor.fragments ?? []).length > 0) {
          this.RichTextContent(floor.fragments ?? [], floor.contentText, fs(16, this.fontScale),
            Theme.textPrimary(this.isDark), fs(23, this.fontScale), 'subpost_parent')
        }
        if (floor.images.length > 0) {
          this.ImageGrid(floor.images)
        }
        this.ReplyMetadata((floor.floor > 0 ? '第' + floor.floor + '楼 ' : '') + this.formatFloorTime(floor.createTime),
          this.parentLiked, this.parentLikeCount, () => { this.toggleParentLike(floor); }, () => { this.onReply?.(); })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 9, bottom: 12, left: 12, right: 12 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  NestedReply(comment: CommentItem) {
    Row({ space: 8 }) {
      this.Avatar(comment.authorAvatar ?? '', comment.author, 34, comment.authorId ?? '')
      Column({ space: 4 }) {
        this.ReplyAuthor(comment.author, comment.authorId ?? '', comment.level ?? 0, comment.isAuthor ?? false)
        if (comment.content.length > 0 || (comment.fragments ?? []).length > 0) {
          this.RichTextContent(comment.fragments ?? [], comment.content, fs(16, this.fontScale),
            Theme.textPrimary(this.isDark), fs(23, this.fontScale), 'subpost_' + comment.commentId)
        }
        if ((comment.images ?? []).length > 0) {
          this.ImageGrid(comment.images ?? [], true, true)
        }
        this.ReplyMetadata(this.formatFloorTime(comment.createTime), comment.isLiked ?? false, comment.likeCount ?? 0,
          () => { this.toggleCommentLike(comment); }, () => { this.onReply?.(comment); })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .id('spc_' + comment.commentId)
    .width('100%')
    .padding({ top: 12, bottom: 8, left: 12, right: 12 })
    .alignItems(VerticalAlign.Top)
    .backgroundColor(this.highlightCommentId === comment.commentId ? Theme.brandBg(this.isDark) : Color.Transparent)
  }

  private async toggleParentLike(floor: FloorItem): Promise<void> {
    if (this.likeInFlight || !/^\d+$/.test(floor.floorId)) {
      return;
    }
    this.likeInFlight = true;
    const previous: boolean = this.parentLiked;
    const previousCount: number = this.parentLikeCount;
    const nextCount: number = Math.max(0, previousCount + (previous ? -1 : 1));
    this.parentLiked = !previous;
    this.parentLikeCount = nextCount;
    try {
      await TiebaService.getInstance().togglePostAgree(this.request.tid, floor.floorId, !previous, 1);
      this.onParentLikeChanged(floor.floorId, !previous, nextCount);
    } catch (e) {
      if (this.pageAlive) {
        this.parentLiked = previous;
        this.parentLikeCount = previousCount;
        this.getUIContext().getPromptAction().showToast({ message: (e as Error).message ?? '操作失败' });
      }
    } finally {
      this.likeInFlight = false;
    }
  }

  @Builder
  Avatar(url: string, author: string, size: number, authorId: string) {
    Stack() {
      Text((author.trim().length > 0 ? author : '吧').substring(0, 1))
        .width(size)
        .height(size)
        .fontSize(Math.max(11, Math.floor(size * 0.44)))
        .fontColor(Color.White)
        .textAlign(TextAlign.Center)
        .backgroundColor(Theme.brand())
        .borderRadius(Radius.full)
      if (url.trim().length > 0) {
        Image(url.trim())
          .width(size)
          .height(size)
          .borderRadius(Radius.full)
          .objectFit(ImageFit.Cover)
          .alt((author.trim().length > 0 ? author : '吧').substring(0, 1))
      }
    }
    .width(size)
    .height(size)
    .onClick(() => {
      this.openUserProfile(authorId, author);
    })
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

  /**
   * 父楼层图预览列表（2026-09-20 预览解耦）：只含父楼层图片，**不再合并楼中楼回复图片**。
   * 楼中楼回复图走独立单张预览（见 ImageGrid 的 singlePreview 分支），预览左右滑只在父楼层图内切换。
   */
  private collectAllImages(): string[] {
    const all: string[] = [];
    if (this.parent) {
      all.push(...this.parent.images);
    }
    return all;
  }

  private getImageGlobalOffset(localImages: string[]): number {
    const all = this.collectAllImages();
    if (localImages.length === 0) return 0;
    const firstUrl = localImages[0];
    const idx = all.indexOf(firstUrl);
    return idx >= 0 ? idx : 0;
  }

  /**
   * 图片宫格（真机错位修复 2026-09-13）：`Grid` 是**可滚动容器**，嵌在 `WaterFlow.FlowItem` 内时
   * 「自测量高度」与「实际渲染高度」可能不一致，布局期用错高度会把后续 FlowItem 摆错位置 → 卡片重叠。
   * 故**显式给出总高** = 行数 × 120 + (行数 − 1) × 6，测量期即终值（与 §4.9 同款修复）。
   * `capMaxWidth`：仅**通栏 / 左栏父楼层卡**传 true（336 封顶）；列内回复卡传 false（跟随列宽）。
   * `singlePreview`（2026-09-20 预览解耦）：true = 楼中楼回复宫格，点开**单张预览**
   * （urls 只传当前这张，左右滑不切图）；false = 父楼层宫格，走父楼层图列表（原全局行为去掉楼中楼图）。
   */
  @Builder
  ImageGrid(images: string[], capMaxWidth: boolean = true, singlePreview: boolean = false) {
    Grid() {
      ForEach(images, (img: string, idx: number) => {
        GridItem() {
          Stack() {
            Image(img)
              .width('100%')
              .height(120)
              .borderRadius(Radius.md * this.cardRadiusScale)
              .objectFit(ImageFit.Cover)
          }
          .width('100%')
          .height(120)
          .onClick(() => {
            // 楼中楼回复宫格（singlePreview=true）：单张预览——urls 只含当前这张（单元素 Swiper 不可滑）。
            if (singlePreview) {
              this.getUIContext().getRouter().pushUrl({
                url: 'pages/ImagePreview',
                params: { urls: [img] }
              }).catch(() => {
                this.getUIContext().getPromptAction().showToast({ message: '图片预览打开失败，请稍后重试' });
              });
              return;
            }
            const allImages = this.collectAllImages();
            const offset = this.getImageGlobalOffset(images);
            this.getUIContext().getRouter().pushUrl({
              url: 'pages/ImagePreview',
              params: { urls: allImages, index: offset + idx }
            }).catch(() => {
              this.getUIContext().getPromptAction().showToast({ message: '图片预览打开失败，请稍后重试' });
            });
          })
        }
      }, (img: string, idx: number) => `${img}_${idx}`)
    }
    .columnsTemplate('1fr 1fr 1fr')
    .columnsGap(6)
    .rowsGap(6)
    .width('100%')
    // 显式总高（错位修复）：行数 × 格高 + 行间隙，消除 FlowItem 内 Grid 自测量的不确定性
    .height(Math.ceil(images.length / 3) * 120 + (Math.ceil(images.length / 3) - 1) * 6)
    // §4.10 SP-J：通栏 / 左栏卡限宽 336 防三列被均分拉宽；列内卡跟随列宽 '100%'。
    // 手机档可用宽 ≈ 296vp < 336 → 封顶不生效（逐像素不变）。
    .constraintSize({ maxWidth: capMaxWidth ? SUBPOST_IMAGE_GRID_MAX_WIDTH : '100%' })
  }

  @Builder
  RichTextContent(fragments: ContentFragment[], fallbackText: string, fontSize: number, fontColor: ResourceColor, lineHeightVal: number, regionKey: string) {
    Column() {
      if (fragments && fragments.length > 0) {
        // 通过 EmojiLoader HTTP + Referer/UA 防盗链下载→PixelMap，完成后 readyEmojiUrls 触发重绘
        ForEach(this.uniqueEmojiUrls(fragments), (emojiUrl: string) => {
          Blank()
            .width(0)
            .height(0)
            .onAppear(() => this.prefetchEmojisWithLoader([emojiUrl]))
        }, (u: string) => u)
        // 单元素 ForEach 包裹（key 含复制重建纪元）：复制完成后自增纪元 → key 变化 → Text 节点整体重建
        // → 选中态随节点销毁清除。纪元未变时 key 相同、节点复用，零额外开销。
        ForEach([this.copyEpochOf(regionKey)], (copyEpoch: number) => {
          Text() {
            ForEach(fragments, (fragment: ContentFragment, idx: number) => {
              if (fragment.type === ContentFragmentType.EMOJI) {
                if ((fragment.imageUrl && fragment.imageUrl.length > 0) && this.hasReadyEmoji(fragment.imageUrl) && EmojiLoader.has(fragment.imageUrl)) {
                  ImageSpan(EmojiLoader.get(fragment.imageUrl) as image.PixelMap)
                    .width(fontSize * 1.2)
                    .height(fontSize * 1.2)
                    .verticalAlign(ImageSpanAlignment.CENTER)
                    .objectFit(ImageFit.Contain)
                    .borderRadius(fontSize * 0.18)
                } else if ((fragment.imageUrl && fragment.imageUrl.length > 0) && this.hasFailedEmoji(fragment.imageUrl) && fragment.text && fragment.text.length > 0) {
                  // EmojiLoader 下载失败（URL 无效）且有描述文本 → 文本兜底，避免空白
                  Span(fragment.text)
                    .fontSize(fontSize)
                    .fontColor(fontColor)
                } else if (fragment.imageUrl && fragment.imageUrl.length > 0) {
                  // 下载中 / 无文本的失败 → 直接 ImageSpan(url) 尝试（CDN 无防盗链，可直连渲染）
                  ImageSpan(fragment.imageUrl)
                    .width(fontSize * 1.2)
                    .height(fontSize * 1.2)
                    .verticalAlign(ImageSpanAlignment.CENTER)
                    .objectFit(ImageFit.Contain)
                    .borderRadius(fontSize * 0.18)
                } else if (fragment.text && fragment.text.length > 0) {
                  Span(fragment.text)
                    .fontSize(fontSize)
                    .fontColor(fontColor)
                }
              } else if (fragment.type === ContentFragmentType.IMAGE) {
                // Skip IMAGE fragments here — they are rendered separately by ImageGrid
              } else if (fragment.type === ContentFragmentType.LINK) {
                // 可点击超链接：主题色高亮 + 下划线，点击弹"是否跳转链接"确认卡片
                Span(fragment.text)
                  .fontSize(fontSize)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.isDark ? '#7FB8FF' : '#2F6BE8')
                  .decoration({
                    type: TextDecorationType.Underline,
                    color: this.isDark ? '#7FB8FF' : '#2F6BE8'
                  })
                  .onClick(() => {
                    this.openPendingLink((fragment.link !== undefined && fragment.link.length > 0) ? fragment.link : fragment.text);
                  })
              } else {
                Span(idx === 0 ? fragment.text.replace(/^(?:[ \t]*\r?\n)+/, '') : fragment.text)
                  .fontSize(fontSize)
                  .fontColor(fontColor)
              }
            }, (fragment: ContentFragment, idx: number) => this.hasReadyEmoji(fragment.imageUrl ?? '')
              ? `${idx}_${fragment.type}_${fragment.text}_${fragment.imageUrl ?? ''}_r`
              : this.hasFailedEmoji(fragment.imageUrl ?? '')
                ? `${idx}_${fragment.type}_${fragment.text}_${fragment.imageUrl ?? ''}_f`
                : `${idx}_${fragment.type}_${fragment.text}_${fragment.imageUrl ?? ''}_w`)
          }
          .fontSize(fontSize)
          .fontColor(fontColor)
          .lineHeight(lineHeightVal)
          .width('100%')
          // 长按选中复制（与 ThreadDetail.RichTextContent 同款，docs/帖子详细页长按复制文字功能补全.md 方案 A）；
          // onCopy 弹「复制成功」并自增纪元清除选中态
          .copyOption(CopyOptions.LocalDevice)
          .draggable(false)
          .onCopy(() => { this.onTextCopied(regionKey); })
        }, (copyEpoch: number) => `${regionKey}_${copyEpoch}`)
      } else {
        // 与 Span 分支同款纪元重建：复制完成后清选中态
        ForEach([this.copyEpochOf(regionKey)], (copyEpoch: number) => {
          Text(fallbackText.replace(/^(?:[ \t]*\r?\n)+/, ''))
            .fontSize(fontSize)
            .fontColor(fontColor)
            .lineHeight(lineHeightVal)
            .width('100%')
            .copyOption(CopyOptions.LocalDevice)
            .draggable(false)
            .onCopy(() => { this.onTextCopied(regionKey); })
        }, (copyEpoch: number) => `${regionKey}_${copyEpoch}`)
      }
    }
    .width('100%')
  }

  // ===== 链接跳转确认（点击楼中楼内容中的链接）=====
  private openPendingLink(url: string): void {
    if (!url || url.length === 0) return;
    this.pendingLinkUrl = url;
    this.showLinkDialog = true;
  }

  private closeLinkDialog(): void {
    this.showLinkDialog = false;
  }

  private copyPendingLink(): void {
    const url: string = this.pendingLinkUrl;
    if (url.length === 0) return;
    try {
      const sysPasteboard = pasteboard.getSystemPasteboard();
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
      sysPasteboard.setData(pasteData, (err: BusinessError | undefined) => {
        this.showLinkDialog = false;
        if (err) {
          this.getUIContext().getPromptAction().showToast({ message: `复制失败：${err.message ?? String(err)}` });
        } else {
          this.getUIContext().getPromptAction().showToast({ message: '链接已复制' });
        }
      });
    } catch (e) {
      this.showLinkDialog = false;
      this.getUIContext().getPromptAction().showToast({ message: '复制失败，请重试' });
    }
  }

  private confirmOpenLink(): void {
    const url: string = this.pendingLinkUrl;
    if (url.length === 0) return;
    const hostCtx = this.getUIContext().getHostContext();
    if (hostCtx === undefined || hostCtx === null) {
      this.copyLinkFallback(url);
      return;
    }
    try {
      const ctx: common.UIAbilityContext = hostCtx as common.UIAbilityContext;
      const want: Want = {
        uri: url,
        action: 'ohos.want.action.viewData',
        type: 'text/plain'
      };
      ctx.startAbility(want).then(() => {
        this.showLinkDialog = false;
      }).catch((err: BusinessError) => {
        // 拉起失败（无可用浏览器等）：复制兜底，避免用户感觉"点了没反应"
        this.showLinkDialog = false;
        this.copyLinkFallback(url);
      });
    } catch (e) {
      this.showLinkDialog = false;
      this.copyLinkFallback(url);
    }
  }

  // 无法拉起系统浏览器时的兜底：复制链接并提示
  private copyLinkFallback(url: string): void {
    try {
      const sysPasteboard = pasteboard.getSystemPasteboard();
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
      sysPasteboard.setData(pasteData, (err: BusinessError | undefined) => {
        const tip: string = err
          ? '无法打开浏览器，且复制失败，请手动复制'
          : '无法打开浏览器，链接已复制到剪贴板';
        this.getUIContext().getPromptAction().showToast({ message: tip });
      });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开浏览器，请手动复制链接' });
    }
  }

  // 链接跳转确认：暗蒙层 + 沉浸光感磨砂玻璃居中卡片 + 竖排操作按钮（风格与收藏页确认弹窗一致）
  @Builder
  LinkConfirmDialog() {
    Stack() {
      // 暗色蒙层，点击外部关闭
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#06000000')
        .onClick(() => { this.closeLinkDialog(); })
        .transition(TransitionEffect.opacity(0).animation({ duration: 180, curve: Curve.EaseOut }))

      Column() {
        // 标题 + URL 预览
        Column({ space: 6 }) {
          Text('是否跳转链接')
            .fontSize(fs(17, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
            .textAlign(TextAlign.Center)
          Text(this.pendingLinkUrl)
            .fontSize(fs(13, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
            .lineHeight(fs(18, this.fontScale))
            .textAlign(TextAlign.Center)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.lg, bottom: Spacing.md })

        // 竖向操作按钮：复制链接 / 确认 / 取消
        Column({ space: Spacing.sm }) {
          Button() {
            Text('复制链接')
              .fontSize(fs(15, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.isDark))
          }
          .width('100%')
          .height(44)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.full)
          .accessibilityText('复制链接')
          .onClick(() => { this.copyPendingLink(); })

          Button() {
            Text('确认')
              .fontSize(fs(15, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
          }
          .width('100%')
          .height(44)
          .backgroundColor(Theme.brand())
          .borderRadius(Radius.full)
          .accessibilityText('确认跳转')
          .onClick(() => { this.confirmOpenLink(); })

          Button() {
            Text('取消')
              .fontSize(fs(15, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.isDark))
          }
          .width('100%')
          .height(44)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.full)
          .accessibilityText('取消')
          .onClick(() => { this.closeLinkDialog(); })
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.lg })
      }
      .width(overlayCardWidth())
      .padding({ top: Spacing.md })
      .backgroundColor(Theme.sheetBg(this.isDark))
      .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
      .systemMaterial(ImmMaterial.control())
      .borderRadius(32 * this.cardRadiusScale)
      .border({ width: { top: 1.5 }, color: Theme.sheetTopGlow(this.isDark) })
      .shadow({ radius: 48, color: '#3D000000', offsetY: 18 })
      // 弹出动画与项目其它居中确认卡一致：缩放 + 上移 + 淡入
      .transition(TransitionEffect.scale({ x: 0.92, y: 0.92 }).combine(TransitionEffect.translate({ y: 24 })).combine(TransitionEffect.opacity(0)).animation({ duration: 220, curve: Curve.EaseOut }))
    }
    .width('100%')
    .height('100%')
    .zIndex(100)
    // 消失动画：整树淡出（根级 transition，否则 if 移除时子级退场不播）
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.IDENTITY,
      TransitionEffect.opacity(0).animation({ duration: 200, curve: Curve.EaseInOut })
    ))
  }

  private async toggleCommentLike(comment: CommentItem): Promise<void> {
    if (this.likeInFlight) {
      return;
    }
    this.likeInFlight = true;
    try {
      await this.doToggleCommentLike(comment);
    } finally {
      this.likeInFlight = false;
    }
  }

  private async doToggleCommentLike(comment: CommentItem): Promise<void> {
    const previous: boolean = comment.isLiked ?? false;
    const next: boolean = !previous;
    const commentId = comment.commentId;
    // 防御：数据缺失真实 id（commentId 形如 "xxx-comment-y" 的合成值）时无法点赞
    if (!/^\d+$/.test(commentId)) {
      this.getUIContext().getPromptAction().showToast({ message: '该回复暂时无法点赞' });
      return;
    }

    this.commentsState = this.commentsState.map((c: CommentItem): CommentItem => {
      if (c.commentId === commentId) {
        const currentCount = c.likeCount ?? 0;
        return {
          commentId: c.commentId,
          author: c.author,
          authorAvatar: c.authorAvatar,
          authorId: c.authorId,
          parentPostId: c.parentPostId,
          replyToId: c.replyToId,
          floor: c.floor,
          content: c.content,
          images: c.images,
          fragments: c.fragments,
          createTime: c.createTime,
          isLiked: next,
          likeCount: Math.max(0, currentCount + (next ? 1 : -1)),
          level: c.level,
          isAuthor: c.isAuthor,
        };
      }
      return c;
    });

    try {
      await TiebaService.getInstance().togglePostAgree(this.request.tid, commentId, next, 2);
    } catch (e) {
      this.commentsState = this.commentsState.map((c: CommentItem): CommentItem => {
        if (c.commentId === commentId) {
          const currentCount = c.likeCount ?? 0;
          return {
          commentId: c.commentId,
          author: c.author,
          authorAvatar: c.authorAvatar,
          authorId: c.authorId,
          parentPostId: c.parentPostId,
          replyToId: c.replyToId,
          floor: c.floor,
          content: c.content,
          images: c.images,
          fragments: c.fragments,
          createTime: c.createTime,
          isLiked: previous,
          likeCount: Math.max(0, currentCount + (next ? -1 : 1)),
          level: c.level,
          isAuthor: c.isAuthor,
        };
        }
        return c;
      });
      const msg = (e as Error).message ?? '操作失败';
      this.getUIContext().getPromptAction().showToast({ message: msg });
    }
  }

  private formatFloorTime(time: string): string {
    if (!time || time.length === 0) return '';
    if (/^\d{1,2}-\d{1,2}\s+\d{1,2}:\d{2}$/.test(time)) return time;
    const match = time.match(/(\d{1,2}-\d{1,2})[ T](\d{1,2}:\d{2})/);
    if (match) return `${match[1]} ${match[2]}`;
    return time;
  }
}

@Entry
@Component
struct SubPostDetail {
  @State request: SubPostPanelRequest | null = null;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    this.request = {
      tid: String(params?.tid ?? ''),
      parentPid: String(params?.pid ?? ''),
      parentFloor: Number(params?.floor ?? 0),
      forumId: String(params?.forumId ?? ''),
      notifyCommentPid: String(params?.notifyCommentPid ?? ''),
      notifyReplyerId: String(params?.notifyReplyerId ?? ''),
      notifyContent: String(params?.notifyContent ?? '')
    };
  }

  build() {
    Column() {
      if (this.request) {
        SubPostReplyPanel({ request: this.request!, onClose: () => { this.getUIContext().getRouter().back(); } })
      }
    }
    .width('100%')
    .height('100%')
  }
}
