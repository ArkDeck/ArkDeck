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

import { HotTrendSection } from '../components/HotTrendSection';
import { PlayoffFeedCard } from '../components/PlayoffFeedCard';
import { SectionHeader } from '../components/SectionHeader';
import { LazyDataSource } from '../datasource/LazyDataSource';
import { FeedItem, PlayoffSlideItem } from '../model/PlayoffModels';
import { createPlayoffFeedItems, createPlayoffSlideItems } from '../mock/PlayoffMockData';
import { FixtureMode, MODE, RELOAD_INTERVAL_MS } from '../fixture/FixtureMode';

const TREND_TITLE: string = 'NBA季后赛';
const WATER_FLOW_COLUMNS: string = '1fr 1fr';
const WATER_FLOW_GAP: number = 4;

@Entry
@Component
struct WaterFlowNestedDemo {
  private dataSource: LazyDataSource<FeedItem> = new LazyDataSource<FeedItem>();
  private slideItems: PlayoffSlideItem[] = createPlayoffSlideItems();
  private reloadDriverId: number = -1;
  @State refreshing: boolean = false;
  // List 的可视高度（vp），用于给嵌套的 WaterFlow 一个确定的视口高度。
  @State listViewportHeight: number = 0;

  aboutToAppear(): void {
    this.reloadFeed();
    this.startReloadDriver();
  }

  aboutToDisappear(): void {
    this.stopReloadDriver();
  }

  /// Drives the feed on a fixed cadence so that any capture window of the same
  /// length contains the same amount of work. Without it a trace of this app is
  /// a trace of an idle device, and two such traces cannot be compared.
  private startReloadDriver(): void {
    if (MODE !== FixtureMode.traceWorkload || this.reloadDriverId !== -1) {
      return;
    }
    this.reloadDriverId = setInterval(() => {
      this.reloadFeed();
    }, RELOAD_INTERVAL_MS);
  }

  private stopReloadDriver(): void {
    if (this.reloadDriverId === -1) {
      return;
    }
    clearInterval(this.reloadDriverId);
    this.reloadDriverId = -1;
  }

  private reloadFeed(): void {
    this.dataSource.reloadData(createPlayoffFeedItems());
  }

  build() {
    Column() {
      Refresh({ refreshing: $$this.refreshing }) {
        List() {
          ListItem() {
            HotTrendSection({
              title: TREND_TITLE,
              slides: this.slideItems
            })
          }
          .width('100%')

          ListItem() {
            SectionHeader({ title: '全部' })
          }
          .width('100%')

          ListItem() {
            WaterFlow() {
              LazyForEach(this.dataSource, (item: FeedItem) => {
                FlowItem() {
                  PlayoffFeedCard({ item: item })
                }
                .width('100%')
              }, (item: FeedItem) => item.id)
            }
            .width('100%')
            .height('100%')
            .padding({ left: 4, right: 4, bottom: 16 })
            .columnsTemplate(WATER_FLOW_COLUMNS)
            .columnsGap(WATER_FLOW_GAP)
            .rowsGap(WATER_FLOW_GAP)
            .cachedCount(4)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .nestedScroll({
              scrollForward: NestedScrollMode.PARENT_FIRST,
              scrollBackward: NestedScrollMode.SELF_FIRST
            })
            .onScrollIndex((first: number, last: number) => {
              console.info('[WaterFlowNestedDemo] visible range: ' + first.toString() + '-' + last.toString());
            })
          }
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .height('100%')
        .listDirection(Axis.Vertical)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .backgroundColor('#F0F0F0')
      }
      .layoutWeight(1)
      .pullToRefresh(true)
      .onRefreshing(() => {
        this.refreshing = true;
        setTimeout(() => {
          this.reloadFeed();
          this.refreshing = false;
        }, 300);
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F0F0F0')
  }
}
