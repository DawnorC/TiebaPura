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

import { CacheManager } from '../cache/CacheManager';
import { AuthManager } from './AuthManager';
import { CACHE_KEY } from '../common/Constants';
import { PersonalContentItem } from '../model/DataModel';

/** 浏览历史上限（沿用旧实现的 50 条） */
const HISTORY_MAX_ITEMS: number = 50;

/** 「最近进入」足迹项（独立于帖子浏览历史，进入吧主页即记录） */
export interface ForumVisitItem {
  name: string;
  forumId: string;
  avatar: string;
  lastVisit: number;
}

/**
 * 「我的 → 浏览历史」的本地记录仓（2026-09-23）。
 *
 * 修复的问题（用户反馈「刚浏览过的帖子在浏览历史里没显示」）：
 * ① 旧实现用 `appendJsonItem` 纯前插，**同一帖每进一次就多一条**——实测真机缓存里
 *    50 条上限被同一帖的 8 条重复记录吃掉，有效帖只剩 ~20 条，新浏览的帖被大量重复项挤到看不见；
 * ② 记录里没有「浏览时间」，展示页只能按 `createTime`（帖子**发布时间**，形如「54 分钟前」「09-21 19:34」）
 *    排序，而这些展示串 `Date.parse` 的结果五花八门（相对时间 → NaN → 0，「MM-DD HH:mm」→ 2001 年）
 *    → 排序结果与浏览先后完全无关，刚浏览的帖（相对时间串）被排到列表最底部。
 *
 * 本仓语义：**按浏览时间倒序，同帖只留最近一次**。
 * - 写入：`visitTime = Date.now()`，同 tid 旧记录全部剔除，新记录置顶（超出上限丢最旧）；
 * - 读取：同 tid 去重（保留最近一次），按 `visitTime` 倒序；无 `visitTime` 的老记录（升级前的数据）
 *   保持其原存储次序（本就是浏览次序）排在末尾 —— **不给老记录伪造时间戳**：它们的浏览时刻已不可考，
 *   伪造成"当前时间"会让整列历史都显示成「刚刚」。老记录的时间文案回落帖子发布时间（createTime）。
 * - 写入串行化（读-改-写不可并发）：快速连续浏览多个帖时，两次写入若交错会互相覆盖丢记录。
 */
export class HistoryStore {
  private static instance: HistoryStore | null = null;
  /** 写入串行链：保证「读 → 改 → 写」原子，绝不并发 */
  private writeChain: Promise<void> = Promise.resolve();

  static getInstance(): HistoryStore {
    if (HistoryStore.instance === null) {
      HistoryStore.instance = new HistoryStore();
    }
    return HistoryStore.instance;
  }

  private cacheKey(accountId: string): string {
    return `${CACHE_KEY.PERSONAL_HISTORY}_${accountId}`;
  }

  private currentAccountId(): string {
    return `${AuthManager.getInstance().getUser()?.userId ?? ''}`.trim();
  }

  /** 读取原始数组（失败/非数组一律按空处理） */
  private async readRaw(accountId: string): Promise<PersonalContentItem[]> {
    const raw = await CacheManager.getInstance().get(this.cacheKey(accountId));
    if (raw === undefined) {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as PersonalContentItem[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (e) {
      return [];
    }
  }

  // ===== 「最近进入」足迹：独立于帖子浏览历史，进入吧主页即记录 =====
  private visitCacheKey(accountId: string): string {
    return `${CACHE_KEY.RECENT_FORUM_VISIT}_${accountId}`;
  }

  /** 记录一次「进入吧」足迹（fire-and-forget）：按吧名去重、置顶、上限 HISTORY_MAX_ITEMS。 */
  recordForumVisit(name: string, forumId: string, avatar: string): Promise<void> {
    this.writeChain = this.writeChain
      .then((): Promise<void> => this.doRecordForumVisit(name, forumId, avatar))
      .catch((): void => {
      });
    return this.writeChain;
  }

  private async doRecordForumVisit(name: string, forumId: string, avatar: string): Promise<void> {
    const acc: string = this.currentAccountId();
    const fname: string = `${name ?? ''}`.trim();
    if (acc.length === 0 || fname.length === 0) {
      return;
    }
    const stored: ForumVisitItem[] = await this.readVisits(acc);
    let effectiveAvatar: string = `${avatar ?? ''}`.trim();
    // 进吧先记空头像、吧头信息后到再补记的时序下：本次入参头像为空而旧足迹已带头像时保留旧头像，
    // 防止重复进入同一吧（重进 / 切排序再触发记录）把已补齐的头像冲回空串。
    if (effectiveAvatar.length === 0) {
      for (const old of stored) {
        if (old.name === fname && (old.avatar ?? '').length > 0) {
          effectiveAvatar = old.avatar ?? '';
          break;
        }
      }
    }
    const next: ForumVisitItem[] = [
      { name: fname, forumId: `${forumId ?? ''}`.trim(), avatar: effectiveAvatar, lastVisit: Date.now() }
    ];
    for (const old of stored) {
      if (old.name === fname) {
        continue;
      }
      next.push(old);
    }
    await CacheManager.getInstance().put(this.visitCacheKey(acc), JSON.stringify(next.slice(0, HISTORY_MAX_ITEMS)));
  }

  /** 回写某吧「最近进入」足迹的头像（足迹在、头像后补的场景：按名网络拉取成功后回写，防下次重建被空值冲掉）。 */
  updateForumVisitAvatar(name: string, avatar: string): Promise<void> {
    this.writeChain = this.writeChain
      .then((): Promise<void> => this.doUpdateForumVisitAvatar(name, avatar))
      .catch((): void => {
      });
    return this.writeChain;
  }

  private async doUpdateForumVisitAvatar(name: string, avatar: string): Promise<void> {
    const acc: string = this.currentAccountId();
    const fname: string = `${name ?? ''}`.trim();
    const fa: string = `${avatar ?? ''}`.trim();
    if (acc.length === 0 || fname.length === 0 || fa.length === 0) {
      return;
    }
    const stored: ForumVisitItem[] = await this.readVisits(acc);
    for (let i = 0; i < stored.length; i++) {
      if (stored[i].name === fname) {
        if ((stored[i].avatar ?? '') !== fa) {
          stored[i] = {
            name: stored[i].name,
            forumId: stored[i].forumId,
            avatar: fa,
            lastVisit: stored[i].lastVisit ?? 0
          };
          await CacheManager.getInstance().put(this.visitCacheKey(acc), JSON.stringify(stored));
        }
        return;
      }
    }
  }

  private async readVisits(accountId: string): Promise<ForumVisitItem[]> {
    const raw = await CacheManager.getInstance().get(this.visitCacheKey(accountId));
    if (raw === undefined) {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as ForumVisitItem[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (e) {
      return [];
    }
  }

  /** 读取「最近进入」足迹（按 lastVisit 倒序）。 */
  async loadForumVisits(): Promise<ForumVisitItem[]> {
    const acc: string = this.currentAccountId();
    if (acc.length === 0) {
      return [];
    }
    const stored: ForumVisitItem[] = await this.readVisits(acc);
    stored.sort((a: ForumVisitItem, b: ForumVisitItem): number => (b.lastVisit ?? 0) - (a.lastVisit ?? 0));
    return stored;
  }

  /** 删除某个吧的「最近进入」足迹。 */
  removeForumVisit(name: string): Promise<void> {
    this.writeChain = this.writeChain
      .then((): Promise<void> => this.doRemoveForumVisit(name))
      .catch((): void => {
      });
    return this.writeChain;
  }

  private async doRemoveForumVisit(name: string): Promise<void> {
    const acc: string = this.currentAccountId();
    const fname: string = `${name ?? ''}`.trim();
    if (acc.length === 0 || fname.length === 0) {
      return;
    }
    const stored: ForumVisitItem[] = await this.readVisits(acc);
    const next: ForumVisitItem[] = stored.filter((v: ForumVisitItem): boolean => v.name !== fname);
    if (next.length !== stored.length) {
      await CacheManager.getInstance().put(this.visitCacheKey(acc), JSON.stringify(next));
    }
  }

  /**
   * 记录一次浏览（打开帖子时调用，fire-and-forget）。未登录（拿不到账号 ID）时静默跳过。
   */
  record(item: PersonalContentItem): Promise<void> {
    this.writeChain = this.writeChain
      .then((): Promise<void> => this.doRecord(item))
      .catch((): void => {
      });
    return this.writeChain;
  }

  private async doRecord(item: PersonalContentItem): Promise<void> {
    const accountId: string = this.currentAccountId();
    const tid: string = `${item.tid ?? ''}`.trim();
    if (accountId.length === 0 || tid.length === 0) {
      return;
    }
    const stored: PersonalContentItem[] = await this.readRaw(accountId);
    const now: number = Date.now();
    // 入参是调用方新建的字面量，就地补字段（避免额外的整对象拷贝）
    item.tid = tid;
    item.accountId = accountId;
    item.visitTime = now;
    const next: PersonalContentItem[] = [item];
    const seen: Set<string> = new Set<string>([tid]);
    for (let i = 0; i < stored.length; i++) {
      const old: PersonalContentItem = stored[i];
      const oldTid: string = `${old.tid ?? ''}`.trim();
      if (oldTid.length === 0 || seen.has(oldTid)) {
        // 同帖旧记录直接丢弃（最近一次已在队首）；无 tid 的脏记录一并清理
        continue;
      }
      seen.add(oldTid);
      next.push(old);
    }
    await CacheManager.getInstance().put(this.cacheKey(accountId), JSON.stringify(next.slice(0, HISTORY_MAX_ITEMS)));
  }

  /**
   * 读取浏览历史（已去重 + 按浏览时间倒序）。空账号 ID 时自动取当前登录账号。
   */
  async load(accountId: string = ''): Promise<PersonalContentItem[]> {
    const acc: string = accountId.trim().length > 0 ? accountId.trim() : this.currentAccountId();
    if (acc.length === 0) {
      return [];
    }
    const stored: PersonalContentItem[] = await this.readRaw(acc);
    const seen: Set<string> = new Set<string>();
    const timed: PersonalContentItem[] = [];
    const legacy: PersonalContentItem[] = [];
    for (const item of stored) {
      const tid: string = `${item.tid ?? ''}`.trim();
      if (tid.length === 0 || seen.has(tid)) {
        continue;
      }
      seen.add(tid);
      if ((item.visitTime ?? 0) > 0) {
        timed.push(item);
      } else {
        legacy.push(item);
      }
    }
    timed.sort((a: PersonalContentItem, b: PersonalContentItem): number => (b.visitTime ?? 0) - (a.visitTime ?? 0));
    return timed.concat(legacy);
  }
}
