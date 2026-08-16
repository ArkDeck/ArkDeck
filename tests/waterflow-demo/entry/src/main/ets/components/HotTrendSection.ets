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

import { PlayoffSlideItem } from '../model/PlayoffModels';
import { PlayoffSlideCard } from './PlayoffSlideCard';

@Component
export struct HotTrendSection {
  @Require @Prop title: string;
  @Require @Prop slides: PlayoffSlideItem[];

  build() {
    Column() {
      Row() {
        Row({ space: 6 }) {
          Text('热榜TOP1')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#EF4444')

          Text('· 18分钟前')
            .fontSize(17)
            .fontColor('#666666')
        }
        .layoutWeight(1)

        Text('下个热点')
          .fontSize(18)
          .fontColor('#111111')
      }
      .width('100%')
      .height(36)
      .padding({ left: 20, right: 20 })

      Text(this.title)
        .width('100%')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#111111')
        .padding({ left: 20, right: 20, bottom: 10 })

      List({ space: 8 }) {
        ForEach(this.slides, (item: PlayoffSlideItem, index: number) => {
          ListItem() {
            PlayoffSlideCard({
              item: item,
              active: index === 0
            })
          }
          .width(186)
          .height(292)
        }, (item: PlayoffSlideItem, index: number) => item.title + index.toString())
      }
      .width('100%')
      .height(292)
      .padding({ left: 20, right: 0 })
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .padding({ top: 18, bottom: 8 })
    .backgroundColor('#FFFFFF')
  }
}
