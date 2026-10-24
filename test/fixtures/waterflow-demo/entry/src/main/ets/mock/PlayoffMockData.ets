/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { FeedItem, FeedItemType, PlayoffSlideItem } from '../model/PlayoffModels';

export function createPlayoffSlideItems(): PlayoffSlideItem[] {
  return [
    new PlayoffSlideItem('NBA季后赛关键战，最后两分钟连续三分改写走势',
      $r('app.media.nba_arena_crowd'), '直播中', '季后赛前线', '4.0万'),
    new PlayoffSlideItem('权威消息：抢七大战主力轮换名单出炉',
      $r('app.media.nba_arena_night'), '权威消息', '战术板', '3.2万'),
    new PlayoffSlideItem('天王山前瞻：内线对位成为胜负手',
      $r('app.media.nba_dunk'), '赛前前瞻', '数据观察', '986'),
    new PlayoffSlideItem('今日集锦：转换进攻提速，三回合打停对手',
      $r('app.media.nba_game_action'), '高光集锦', '攻防节奏', '1288'),
    new PlayoffSlideItem('伤病名单更新，替补席深度影响系列赛',
      $r('app.media.nba_court_crowd'), '阵容更新', '伤病回归', '266')
  ];
}

export function createPlayoffFeedItems(): FeedItem[] {
  return [
    new FeedItem('video-0', FeedItemType.Result, '最后两分钟连续三分，主场完成逆转', '季后赛前线', '4.0万', 'TOP1',
      0.62, '#1E293B', $r('app.media.nba_arena_crowd')),
    new FeedItem('video-1', FeedItemType.Result, '抢七夜的防守强度：每个回合都像决胜球', '战术板', '2333', 'G7',
      0.5625, '#0F172A', $r('app.media.nba_arena_night')),
    new FeedItem('video-2', FeedItemType.Result, '替补席爆发，第二阵容打出关键反击波', '数据观察', '210', '',
      0.72, '#334155', $r('app.media.nba_game_action')),
    new FeedItem('related-words-0', FeedItemType.RelatedWords, '大家还在搜', '', '', '', 1, '#FFFFFF',
      $r('app.media.nba_court_crowd'), [
        'NBA季后赛赛程',
        '东西部半决赛对阵',
        '今日季后赛集锦',
        '抢七大战什么时候打',
        '季后赛得分榜',
        '关键球员伤病名单',
        '主场优势有多重要',
        '总决赛预测'
      ]),
    new FeedItem('video-3', FeedItemType.Result, '外线手感回暖，单节命中率拉满', '投篮热区', '1.0万', '',
      0.68, '#7F1D1D', $r('app.media.nba_dunk')),
    new FeedItem('video-4', FeedItemType.Result, '内线护框改变比赛走势，连续送出封盖', '禁区报告', '2', '',
      0.84, '#1D4ED8', $r('app.media.nba_court_crowd')),
    new FeedItem('video-5', FeedItemType.Result, '慢镜头拆解：挡拆后的弱侧空切为什么成立', '战术显微镜', '986', '',
      0.5625, '#4C1D95', $r('app.media.nba_game_action')),
    new FeedItem('video-6', FeedItemType.Result, '客场消音时刻，压哨球让系列赛回到同一起跑线', '现场直击', '321', '',
      0.78, '#111827', $r('app.media.nba_stands')),
    new FeedItem('video-7', FeedItemType.Result, '巨星对位升级：从第一节就开始互相点名', '焦点对决', '642', '',
      0.64, '#92400E', $r('app.media.nba_arena_night')),
    new FeedItem('video-8', FeedItemType.Result, '转换进攻提速，三回合打停对手', '攻防节奏', '1288', '',
      0.5625, '#065F46', $r('app.media.nba_dunk')),
    new FeedItem('video-9', FeedItemType.Result, '板凳席情绪拉满，暂停回来连追8分', '替补席观察', '402', '',
      0.9, '#312E81', $r('app.media.nba_arena_crowd')),
    new FeedItem('video-10', FeedItemType.Result, '末节失误复盘：一次传球选择改变胜负', '复盘室', '734', '',
      0.7, '#7C2D12', $r('app.media.nba_game_action')),
    new FeedItem('video-11', FeedItemType.Result, '主场声浪太强，罚球线前全场起立', '球馆声音', '911', '',
      0.5625, '#334155', $r('app.media.nba_stands')),
    new FeedItem('video-12', FeedItemType.Result, '伤愈复出的第一场，他把防守强度带回来了', '伤病回归', '266', '',
      0.76, '#1F2937', $r('app.media.nba_court_crowd')),
    new FeedItem('video-13', FeedItemType.Result, '系列赛天王山：篮板和罚球决定细节', '赛前笔记', '510', '',
      0.7, '#7F1D1D', $r('app.media.nba_arena_crowd')),
    new FeedItem('video-14', FeedItemType.Result, '防守换人策略调整后，持球人效率明显下降', '教练席', '188', '',
      0.84, '#1E3A8A', $r('app.media.nba_arena_night')),
    new FeedItem('video-15', FeedItemType.Result, '高位策应连续找到空位，团队篮球打出高潮', '配合精选', '1112', '',
      0.5625, '#14532D', $r('app.media.nba_game_action')),
    new FeedItem('video-16', FeedItemType.Result, '关键回合数据：谁在最后五分钟接管比赛', '关键时刻', '607', '',
      0.88, '#581C87', $r('app.media.nba_dunk')),
    new FeedItem('video-17', FeedItemType.Result, '客队更衣室视角：赢下第一场后的冷静复盘', '幕后记录', '95', '',
      0.66, '#713F12', $r('app.media.nba_stands')),
    new FeedItem('video-18', FeedItemType.Result, '暂停布置后的第一攻，教科书级别执行', '战术回合', '380', '',
      0.74, '#0F172A', $r('app.media.nba_court_crowd')),
    new FeedItem('video-19', FeedItemType.Result, '赛后快问快答：下一场轮换会怎么变', '快问快答', '709', '',
      0.5625, '#7C2D12', $r('app.media.nba_arena_crowd')),
    new FeedItem('video-20', FeedItemType.Result, '完整比赛路线：从开局试探到末节收官', '全场复盘', '1500', '',
      0.8, '#1E293B', $r('app.media.nba_game_action'))
  ];
}
