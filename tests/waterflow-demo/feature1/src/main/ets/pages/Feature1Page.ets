@Entry
@Component
struct Feature1Page {
  build() {
    Column() {
      Text('Feature module installed alongside entry')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
