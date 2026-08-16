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

import { FeedItem, FeedItemType } from '../model/PlayoffModels';

@Component
export struct PlayoffFeedCard {
  @Require @Prop item: FeedItem;

  @Builder
  private resultCard() {
    Stack() {
      Image(this.item.coverImage)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .backgroundColor(this.item.coverColor)

      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#18000000')

      Column() {
        if (this.item.badge.length > 0) {
          Row() {
            Text(this.item.badge)
              .fontSize(13)
              .fontColor('#222222')
              .fontWeight(FontWeight.Medium)
              .height(27)
              .padding({ left: 8, right: 8 })
              .borderRadius(5)
              .backgroundColor('#EFFFFFFF')
          }
          .width('100%')
          .justifyContent(FlexAlign.Start)
        }

        Blank()

        Text(this.item.title)
          .width('100%')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Bold)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .ellipsisMode(EllipsisMode.END)

        Row({ space: 6 }) {
          Column()
            .width(18)
            .height(18)
            .borderRadius(9)
            .backgroundColor('#2563EB')

          Text(this.item.source)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .ellipsisMode(EllipsisMode.END)

          Text('♡ ' + this.item.likes)
            .fontSize(13)
            .fontColor('#FFFFFF')
        }
        .width('100%')
        .height(28)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
    }
    .width('100%')
    .aspectRatio(this.item.aspectRatio)
    .borderRadius(5)
    .clip(true)
    .backgroundColor(this.item.coverColor)
  }

  @Builder
  private relatedWordsCard() {
    Column() {
      Text(this.item.title)
        .width('100%')
        .fontSize(18)
        .fontColor('#111111')
        .fontWeight(FontWeight.Medium)
        .padding({ left: 12, top: 12, bottom: 8 })

      List({ space: 7 }) {
        ForEach(this.item.relatedWords, (word: string) => {
          ListItem() {
            Text(word)
              .width('100%')
              .height(34)
              .fontSize(14)
              .fontColor('#333333')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .ellipsisMode(EllipsisMode.END)
              .padding({ left: 10, right: 10 })
              .borderRadius(17)
              .backgroundColor('#F5F5F5')
          }
          .width('100%')
          .height(34)
        }, (word: string) => word)
      }
      .width('100%')
      .height(this.item.relatedWords.length * 41)
      .listDirection(Axis.Vertical)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
    }
    .width('100%')
    .padding({ left: 8, right: 8, bottom: 8 })
    .backgroundColor('#FFFFFF')
    .borderRadius(5)
  }

  build() {
    if (this.item.type === FeedItemType.RelatedWords) {
      this.relatedWordsCard()
    } else {
      this.resultCard()
    }
  }
}
