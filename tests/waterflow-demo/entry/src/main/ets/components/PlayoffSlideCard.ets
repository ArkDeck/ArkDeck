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

@Component
export struct PlayoffSlideCard {
  @Require @Prop item: PlayoffSlideItem;
  @Require @Prop active: boolean;

  build() {
    Stack() {
      Image(this.item.image)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .backgroundColor('#111827')

      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#22000000')

      Column() {
        Row() {
          Text(this.item.label)
            .fontSize(14)
            .fontColor(this.active ? '#E6FFFA' : '#222222')
            .fontWeight(FontWeight.Medium)
            .height(26)
            .padding({ left: 8, right: 8 })
            .borderRadius(5)
            .backgroundColor(this.active ? '#662563EB' : '#EFFFFFFF')
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)

        Blank()

        Text(this.item.title)
          .width('100%')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .ellipsisMode(EllipsisMode.END)

        Row({ space: 6 }) {
          Column()
            .width(18)
            .height(18)
            .borderRadius(9)
            .backgroundColor(this.active ? '#2563EB' : '#F59E0B')

          Text(this.item.source)
            .fontSize(14)
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .ellipsisMode(EllipsisMode.END)

          Text('♡ ' + this.item.likes)
            .fontSize(14)
            .fontColor('#FFFFFF')
        }
        .width('100%')
        .height(28)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 10, right: 10, top: 10, bottom: 10 })
    }
    .width(186)
    .height(292)
    .borderRadius(5)
    .clip(true)
    .border({
      width: this.active ? 2 : 0,
      color: '#FFFFFF'
    })
  }
}
