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

import { USE_BLANKET_RELOAD } from '../fixture/FixtureMode';

export class LazyDataSource<T> implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private data: T[] = [];
  private signatures: string[] = [];

  public totalCount(): number {
    return this.data.length;
  }

  public getData(index: number): T {
    return this.data[index];
  }

  /// Replaces the backing data and notifies the change.
  ///
  /// Which notification gets sent is what this demo is for. The blanket path
  /// always calls `notifyDataReload()`, so LazyForEach discards and rebuilds
  /// every item — a reload carrying the same keys still pays a full re-measure
  /// of the whole nested WaterFlow. The narrow path compares the incoming rows
  /// against the previous ones by identity signature: an unchanged key sequence
  /// emits per-index `onDataChange` only for rows that really differ, an
  /// identical payload emits nothing, and any structural difference still falls
  /// back to the full reload.
  ///
  /// See FixtureMode.USE_BLANKET_RELOAD.
  public reloadData(data: T[]): void {
    const next: string[] = LazyDataSource.signaturesOf(data);
    const previous: string[] = this.signatures;
    this.data = data;
    this.signatures = next;

    if (USE_BLANKET_RELOAD || previous.length !== next.length) {
      this.notifyDataReload();
      return;
    }
    const changed: number[] = [];
    for (let index = 0; index < next.length; index++) {
      if (previous[index] !== next[index]) {
        changed.push(index);
      }
    }
    if (changed.length === 0) {
      return;
    }
    for (const index of changed) {
      this.notifyDataChange(index);
    }
  }

  private static signaturesOf<T>(data: T[]): string[] {
    const result: string[] = [];
    for (const entry of data) {
      const row = entry as Record<string, Object>;
      const id = row.id === undefined ? '' : row.id.toString();
      const title = row.title === undefined ? '' : row.title.toString();
      const likes = row.likes === undefined ? '' : row.likes.toString();
      const badge = row.badge === undefined ? '' : row.badge.toString();
      result.push(`${id} ${title} ${likes} ${badge}`);
    }
    return result;
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  private notifyDataReload(): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    })
  }

  private notifyDataChange(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataChange(index);
    })
  }
}
