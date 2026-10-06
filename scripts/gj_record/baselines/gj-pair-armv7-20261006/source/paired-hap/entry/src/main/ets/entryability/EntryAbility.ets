import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0xD001, 'ArkDeckGjPair', 'EntryAbility onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        hilog.error(0xD001, 'ArkDeckGjPair', 'loadContent failed code=%{public}d', error.code);
      } else {
        hilog.info(0xD001, 'ArkDeckGjPair', 'EntryAbility content ready');
      }
    });
  }

  onForeground(): void {
    hilog.info(0xD001, 'ArkDeckGjPair', 'EntryAbility foreground');
  }

  onDestroy(): void {
    hilog.info(0xD001, 'ArkDeckGjPair', 'EntryAbility destroyed');
  }
}
