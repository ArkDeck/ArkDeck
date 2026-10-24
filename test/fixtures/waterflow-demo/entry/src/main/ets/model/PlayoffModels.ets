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

export enum FeedItemType {
  Result,
  RelatedWords
}

export class FeedItem {
  public id: string;
  public type: FeedItemType;
  public title: string;
  public source: string;
  public likes: string;
  public badge: string;
  public aspectRatio: number;
  public coverColor: string;
  public coverImage: ResourceStr;
  public relatedWords: string[];

  constructor(id: string, type: FeedItemType, title: string, source: string, likes: string, badge: string,
    aspectRatio: number, coverColor: string, coverImage: ResourceStr, relatedWords: string[] = []) {
    this.id = id;
    this.type = type;
    this.title = title;
    this.source = source;
    this.likes = likes;
    this.badge = badge;
    this.aspectRatio = aspectRatio;
    this.coverColor = coverColor;
    this.coverImage = coverImage;
    this.relatedWords = relatedWords;
  }
}

export class PlayoffSlideItem {
  public title: string;
  public image: ResourceStr;
  public label: string;
  public source: string;
  public likes: string;

  constructor(title: string, image: ResourceStr, label: string, source: string, likes: string) {
    this.title = title;
    this.image = image;
    this.label = label;
    this.source = source;
    this.likes = likes;
  }
}
