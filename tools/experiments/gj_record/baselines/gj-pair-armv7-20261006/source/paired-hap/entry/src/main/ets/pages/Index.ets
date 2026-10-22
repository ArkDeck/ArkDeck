import nativePair from 'libarkdeck_gj.so';
import { hilog } from '@kit.PerformanceAnalysisKit';

@Entry
@Component
struct Index {
  @State marker: string = 'NATIVE_NOT_CHECKED';
  @State result: string = 'NOT_CHECKED';
  private rows: number[] = [1, 2, 3, 4, 5, 6, 7, 8];

  aboutToAppear(): void {
    // The import and actual call keep the app-owned ELF in this process's maps.
    this.marker = nativePair.marker();
    const sum = nativePair.add(19, 23);
    const knownMarker = this.marker === 'arkdeck-gj3-baseline-v1-20261006' ||
      this.marker === 'arkdeck-gj3-candidate-v3-20261006';
    this.result = knownMarker && sum === 42 ? 'NAPI_CHECK_OK' : 'NAPI_CHECK_FAILED';
    hilog.info(0xD001, 'ArkDeckGjPair', '%{public}s marker=%{public}s add=%{public}d',
      this.result, this.marker, sum);
  }

  build() {
    Column({ space: 12 }) {
      Text('ArkDeck ARMv7 pair proposal').fontSize(22)
      Text(this.marker).id('arkdeck-native-marker').fontSize(16)
      Text(this.result).id('arkdeck-native-check').fontSize(18)
      Text('Native add(19, 23) must return 42').fontSize(14)
      List({ space: 8 }) {
        ForEach(this.rows, (row: number) => {
          ListItem() { Text('Capture row ' + row).fontSize(18).padding(12) }
        }, (row: number) => row.toString())
      }.width('100%').height(320)
    }.width('100%').height('100%').padding(24).backgroundColor('#F1F5F9')
  }
}
